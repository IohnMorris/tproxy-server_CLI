#!/usr/bin/env python3
"""Interactive management dashboard for TG-Proxy."""
import asyncio
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from urllib.parse import quote

from textual import work
from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, Collapsible, DataTable, Footer, Header, Input, Label, Select, Static, TextArea

PROFILES_FILE = Path('/etc/tproxy-server/profiles.json')
CONFIG_FILE = Path('/etc/tproxy-server/config.json')
SITE_FILE = Path('/srv/tproxy-site/index.html')
MTPROXY_ENV = Path('/etc/mtproxy/mtproxy.env')
TRAFFIC_FILE = Path('/etc/tproxy-server/traffic_stats.json')
VERSION_FILE = Path('/etc/tproxy-server/panel-version')
LANG_FILE = Path('/etc/tproxy-server/panel-language')
TAGS_URL = 'https://api.github.com/repos/IohnMorris/tproxy-server_CLI/tags?per_page=100'
PANEL_REPO = 'IohnMorris/tproxy-server_CLI'
CLI_BIN = '/usr/local/bin/tg-proxy'
CORE_DIR = '/opt/tproxy-server'
MODES = ('https', 'https-lanes', 'websocket', 'websocket-lanes')
LANG = 'en' if os.environ.get('PROXY_LANG') == 'en' else 'ru'

def tr(ru, en):
    return en if LANG == 'en' else ru

ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')


def version_tuple(tag):
    match = re.fullmatch(r'v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', tag)
    return tuple(map(int, match.groups())) if match else None


def latest_tag():
    request = urllib.request.Request(TAGS_URL, headers={'User-Agent': 'tg-proxy-panel', 'Accept': 'application/vnd.github+json'})
    with urllib.request.urlopen(request, timeout=8) as response:
        tags = json.load(response)
    versions = [(version_tuple(item.get('name', '')), item.get('name', '')) for item in tags if isinstance(item, dict)]
    versions = [item for item in versions if item[0] is not None]
    return max(versions, default=(None, None))[1]


def panel_update():
    """Identify unversioned installs before offering a tagged release."""
    tag = latest_tag()
    if not tag:
        return None
    try:
        current = VERSION_FILE.read_text(encoding='utf-8').strip()
    except OSError:
        current = ''
    if version_tuple(current):
        return (tag, current) if version_tuple(tag) > version_tuple(current) else None

    def matches(ref):
        for filename, path in (('install.sh', Path(CLI_BIN)), ('tproxy_ui.py', Path(__file__).resolve())):
            url = f'https://raw.githubusercontent.com/{PANEL_REPO}/{quote(ref, safe="")}/{filename}'
            request = urllib.request.Request(url, headers={'User-Agent': 'tg-proxy-panel'})
            with urllib.request.urlopen(request, timeout=8) as response:
                if path.read_bytes() != response.read():
                    return False
        return True

    if matches(tag):
        try:
            VERSION_FILE.parent.mkdir(parents=True, exist_ok=True)
            VERSION_FILE.write_text(tag + '\n', encoding='utf-8')
        except OSError:
            pass
        return None
    if matches('main'):
        request = urllib.request.Request(
            f'https://api.github.com/repos/{PANEL_REPO}/compare/{quote(tag, safe="")}...main',
            headers={'User-Agent': 'tg-proxy-panel', 'Accept': 'application/vnd.github+json'})
        with urllib.request.urlopen(request, timeout=8) as response:
            comparison = json.load(response)
        if comparison.get('status') in ('identical', 'ahead'):
            try:
                VERSION_FILE.parent.mkdir(parents=True, exist_ok=True)
                VERSION_FILE.write_text('main\n', encoding='utf-8')
            except OSError:
                pass
            return None
    return (tag, current)


def core_update():
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    installed = subprocess.run(['git', '-C', CORE_DIR, 'rev-parse', 'HEAD'], capture_output=True, text=True, timeout=8, check=True, env=env).stdout.strip()
    remote = subprocess.run(['git', '-C', CORE_DIR, 'ls-remote', 'origin', 'HEAD'], capture_output=True, text=True, timeout=12, check=True, env=env).stdout.split()
    if not remote or not re.fullmatch(r'[0-9a-f]{40,64}', installed) or not re.fullmatch(r'[0-9a-f]{40,64}', remote[0]):
        raise ValueError('Invalid Git revision')
    return (installed, remote[0]) if installed != remote[0] else None


def format_size(value):
    units = ('B', 'KiB', 'MiB', 'GiB', 'TiB') if LANG == 'en' else ('Б', 'КиБ', 'МиБ', 'ГиБ', 'ТиБ')
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f'{value:.1f} {unit}'
        value /= 1024


def collect_server_metrics(profiles):
    """Collect a read-only snapshot without blocking the interface."""
    def run(*args):
        try:
            result = subprocess.run(args, capture_output=True, text=True, timeout=4, check=False)
            return result.stdout if result.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired):
            return None

    def cpu_sample():
        values = [int(x) for x in Path('/proc/stat').read_text().splitlines()[0].split()[1:]]
        return values[3] + values[4], sum(values[:8])

    try:
        idle1, total1 = cpu_sample()
        time.sleep(0.12)
        idle2, total2 = cpu_sample()
        cpu = f'{100 * (1 - (idle2 - idle1) / (total2 - total1)):.0f}%' if total2 > total1 else '—'
    except (OSError, ValueError, IndexError):
        cpu = '—'
    try:
        memory = {line.split(':', 1)[0]: int(line.split(':', 1)[1].split()[0]) * 1024
                  for line in Path('/proc/meminfo').read_text().splitlines() if ':' in line}
        total = memory['MemTotal']
        used = total - memory.get('MemAvailable', memory.get('MemFree', 0))
        ram = f'{format_size(used)}/{format_size(total)} ({used * 100 / total:.0f}%)'
    except (OSError, ValueError, KeyError, IndexError, ZeroDivisionError):
        ram = '—'
    try:
        disk = shutil.disk_usage('/')
        disk_text = f'{format_size(disk.used)}/{format_size(disk.total)} ({disk.used * 100 / disk.total:.0f}%)'
    except (OSError, ZeroDivisionError):
        disk_text = '—'
    try:
        load = f'{os.getloadavg()[0]:.2f}'
    except (OSError, AttributeError):
        load = '—'

    states = []
    for name, label in (('tproxy-server', 'proxy'), ('mtproxy', 'MTProxy'), ('caddy', 'Caddy')):
        state = run('systemctl', 'is-active', name)
        status = tr('работает', 'running') if state and state.strip() == 'active' else tr('неизвестно/остановлен', 'unknown/stopped')
        states.append(f'{label}: {status}')

    connections = []
    per_profile = {p.get('name', ''): [None, None] for p in profiles}
    for profile in profiles:
        port = str(profile.get('backend', '')).rsplit(':', 1)[-1]
        if not port.isdigit():
            connections = None
            break
        output = run('ss', '-Htan', 'state', 'established', f'( dport = :{port} )')
        if output is None:
            connections = None
            break
        count = len(output.splitlines())
        connections.append(count)
        per_profile[profile.get('name', '')][0] = (count + 5) // 6
    if connections is None:
        online = '—'
    else:
        users = sum((count + 5) // 6 for count in connections)
        online = tr(f'~{users} чел. ({sum(connections)} соед.)', f'~{users} users ({sum(connections)} connections)')

    try:
        saved = json.loads(TRAFFIC_FILE.read_text(encoding='utf-8'))
    except FileNotFoundError:
        saved = {}
    except (OSError, ValueError):
        saved = None
    nft = run('nft', '-j', 'list', 'table', 'inet', 'tg_proxy_stats')
    traffic = None
    if saved is not None and nft is not None:
        try:
            names = {p.get('name', '') for p in profiles}
            totals = {name: sum(int(saved.get(name, {}).get(direction, 0)) for direction in ('rx', 'tx')) for name in names}
            for item in json.loads(nft).get('nftables', []):
                rule = item.get('rule', {})
                comment = rule.get('comment', '')
                if (comment.startswith('rx_') or comment.startswith('tx_')) and comment[3:] in names:
                    totals[comment[3:]] += sum(int(expr['counter'].get('bytes', 0)) for expr in rule.get('expr', []) if 'counter' in expr)
            traffic = sum(totals.values())
            for name, total in totals.items():
                per_profile[name][1] = total
        except (ValueError, TypeError, AttributeError):
            traffic = None
    disk_label = tr('Диск', 'Disk')
    online_label = tr('Онлайн', 'Online')
    traffic_label = tr('Трафик всего', 'Total traffic')
    summary = (f'CPU: {cpu} • RAM: {ram} • {disk_label}: {disk_text} • Load: {load}\n'
            f'{online_label}: {online} • {traffic_label}: {format_size(traffic) if traffic is not None else "—"} • '
            + '  '.join(states))
    return summary, per_profile


def make_link(profile, config):
    host = config.get('public_hostname') or config.get('hostname')
    if not host:
        raise ValueError(tr('Домен не найден в конфигурации', 'Domain not found in configuration'))
    path = config.get('base_path') or ''
    secret = profile['secret'].removeprefix('dd')
    if path:
        secret = base64.urlsafe_b64encode(b'\x70' + bytes.fromhex(secret)).decode().rstrip('=')
    server = host + ('/' + path if path else '')
    return 'https://t.me/webproxy?server=' + quote(server, safe='') + '&secret=' + secret


def profile_statistics(profile):
    name = profile.get('name', '')
    try:
        saved = json.loads(TRAFFIC_FILE.read_text(encoding='utf-8')).get(name, {})
        rx, tx = int(saved.get('rx', 0)), int(saved.get('tx', 0))
        result = subprocess.run(['nft', '-j', 'list', 'table', 'inet', 'tg_proxy_stats'], capture_output=True, text=True, timeout=4, check=True)
        for item in json.loads(result.stdout).get('nftables', []):
            rule = item.get('rule', {})
            amount = sum(int(expr['counter'].get('bytes', 0)) for expr in rule.get('expr', []) if 'counter' in expr)
            if rule.get('comment') == 'rx_' + name: rx += amount
            if rule.get('comment') == 'tx_' + name: tx += amount
        port = str(profile.get('backend', '')).rsplit(':', 1)[-1]
        if not port.isdigit(): raise ValueError('Invalid backend port')
        result = subprocess.run(['ss', '-Htan', 'state', 'established', f'( dport = :{port} )'], capture_output=True, text=True, timeout=4, check=True)
        connections = len(result.stdout.splitlines())
        created = saved.get('created_at', '—')
        return tr(f'Создан: {created} • Онлайн: ~{(connections + 5) // 6} ({connections} соед.)\nRX: {format_size(rx)} • TX: {format_size(tx)} • Всего: {format_size(rx + tx)}',
                  f'Created: {created} • Online: ~{(connections + 5) // 6} ({connections} connections)\nRX: {format_size(rx)} • TX: {format_size(tx)} • Total: {format_size(rx + tx)}')
    except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
        return tr('Статистика недоступна', 'Statistics unavailable')


class Dialog(ModalScreen):
    CSS = '''
    Dialog { align: center middle; background: $background 70%; }
    #dialog { width: 76; max-width: 95%; height: auto; max-height: 90%; border: round $accent; background: $surface; padding: 1 2; }
    #dialog-body { height: auto; max-height: 1fr; }
    #dialog-buttons { height: auto; margin-top: 1; }
    #dialog-buttons Button { width: 1fr; margin-right: 1; }
    Input, Select { margin-bottom: 1; }
    '''
    def __init__(self, title, fields=(), message='', confirm=None, cancel=None):
        super().__init__()
        self.title_text, self.fields, self.message, self.confirm = title, fields, message, confirm
        self.confirm = confirm or tr('Применить', 'Apply')
        self.cancel = cancel or tr('Отмена', 'Cancel')

    def compose(self) -> ComposeResult:
        with Vertical(id='dialog'):
            yield Label(self.title_text, classes='dialog-title')
            with VerticalScroll(id='dialog-body'):
                if self.message:
                    yield Static(self.message, markup=False)
                for key, label, value, choices in self.fields:
                    yield Label(label)
                    if choices:
                        yield Select([(item, item) for item in choices], value=value, allow_blank=False, id=key)
                    else:
                        yield Input(value=value, id=key)
            with Horizontal(id='dialog-buttons'):
                yield Button(self.cancel, id='cancel')
                yield Button(self.confirm, id='confirm', variant='primary')

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == 'cancel':
            self.dismiss(None)
        elif event.button.id == 'confirm':
            self.dismiss({key: self.query_one('#' + key).value for key, _, _, _ in self.fields})


class TextDialog(ModalScreen):
    CSS = '''
    TextDialog { align: center middle; background: $background 70%; }
    #box { width: 100; max-width: 96%; height: 85%; border: round $accent; background: $surface; padding: 1 2; }
    #text { height: 1fr; }
    #buttons { height: auto; }
    #buttons Button { margin-right: 1; }
    '''
    def __init__(self, title, content, copy=False, editable=False):
        super().__init__()
        self.title_text, self.content, self.copy, self.editable = title, content, copy, editable

    def compose(self) -> ComposeResult:
        with Vertical(id='box'):
            yield Label(self.title_text)
            yield TextArea(self.content, read_only=not self.editable, id='text', show_line_numbers=self.editable)
            with Horizontal(id='buttons'):
                yield Button(tr('Закрыть', 'Close'), id='close')
                if self.copy:
                    yield Button(tr('Копировать всё', 'Copy all'), id='copy', variant='primary')
                if self.editable:
                    yield Button(tr('Очистить', 'Clear'), id='clear', variant='warning')
                    yield Button(tr('Сохранить', 'Save'), id='save', variant='primary')

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == 'copy':
            self.app.copy_to_clipboard(self.query_one(TextArea).text)
            self.app.notify(tr('Отправлено в буфер обмена терминала', 'Sent to terminal clipboard'))
        elif event.button.id == 'clear':
            self.query_one(TextArea).load_text('')
            self.query_one(TextArea).focus()
        elif event.button.id == 'save':
            self.dismiss(self.query_one(TextArea).text)
        elif event.button.id == 'close':
            self.dismiss(None)


class ProfileDialog(ModalScreen):
    CSS = '''
    ProfileDialog { align: center middle; background: $background 70%; }
    #profile-card { width: 80; max-width: 95%; height: auto; max-height: 90%; border: round $accent; background: $surface; padding: 1 2; }
    #profile-content { height: auto; max-height: 1fr; }
    #profile-buttons { height: auto; margin-top: 1; }
    #profile-buttons Button { margin-right: 1; }
    '''

    def __init__(self, profile, link, error='', statistics=''):
        super().__init__()
        self.profile, self.link, self.error, self.statistics = profile, link, error, statistics

    def compose(self) -> ComposeResult:
        with Vertical(id='profile-card'):
            yield Label(tr('Профиль: ', 'Profile: ') + str(self.profile.get('name', '')), classes='dialog-title')
            with VerticalScroll(id='profile-content'):
                yield Static(tr('Транспорт: ', 'Transport: ') + str(self.profile.get('carrier_mode', 'https')), markup=False)
                yield Static('Backend: ' + str(self.profile.get('backend', '')), markup=False)
                yield Static(self.statistics, markup=False)
                yield Label(tr('Ссылка для подключения', 'Connection link'))
                if self.link:
                    yield Input(value=self.link, id='profile-link')
                else:
                    yield Static(tr('Не удалось сформировать ссылку: ', 'Could not create link: ') + self.error, markup=False)
            with Horizontal(id='profile-buttons'):
                yield Button(tr('Закрыть', 'Close'), id='profile-close')
                if self.link:
                    yield Button(tr('Копировать ссылку', 'Copy link'), id='profile-copy', variant='primary')

    def on_button_pressed(self, event: Button.Pressed) -> None:
        event.stop()
        if event.button.id == 'profile-copy':
            self.app.copy_to_clipboard(self.link)
            self.app.notify(tr('Ссылка отправлена в буфер обмена терминала', 'Link sent to terminal clipboard'))
        elif event.button.id == 'profile-close':
            self.dismiss()


class TProxyDashboard(App):
    TITLE = tr('TG-Proxy • Центр управления', 'TG-Proxy • Control Center')
    CSS = '''
    Screen { layout: vertical; }
    #content { height: 1fr; layout: horizontal; }
    #profiles { width: 2fr; border: round $primary; padding: 0 1; }
    #actions { width: 1fr; min-width: 32; border: round $accent; padding: 0 1; }
    .title, .dialog-title { text-style: bold; color: $accent; padding: 1 0; }
    #status { height: auto; padding: 0 1; }
    #server-metrics { height: auto; padding: 0 1; color: $text-muted; }
    DataTable { height: 1fr; }
    #actions Button { width: 100%; margin-bottom: 1; }
    .section-title { color: $text-muted; text-style: bold; padding: 1 0 0 0; margin-bottom: 1; }
    #actions #update { background: #7846b8; color: white; }
    #actions #update:hover { background: #925bd0; }
    #actions #update:focus { background: #925bd0; }
    #actions Collapsible { margin-bottom: 1; border: round $panel; padding: 0 1; }
    #actions CollapsibleTitle { color: $text; text-style: bold; }
    #actions Collapsible > Button { margin-bottom: 1; }
    .narrow #content { layout: vertical; }
    .narrow #profiles { width: 100%; height: 40%; }
    .narrow #actions { width: 100%; height: 60%; }
    '''
    BINDINGS = [('f5', 'refresh_data', tr('Обновить', 'Refresh')), ('q', 'quit', tr('Выход', 'Quit'))]

    def __init__(self):
        super().__init__()
        self.profiles = []
        self.profile_metrics = {}
        self.busy = False
        self.metrics_busy = False

    def get_system_commands(self, screen):
        # The command palette should expose the theme selector only.
        for command in super().get_system_commands(screen):
            if 'theme' in command.title.lower():
                yield command

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield Static(tr('Загрузка...', 'Loading...'), id='status')
        yield Static(tr('Загрузка сведений о сервере...', 'Loading server information...'), id='server-metrics', markup=False)
        with Horizontal(id='content'):
            with Vertical(id='profiles'):
                yield Label(tr('ПРОФИЛИ — выберите строку', 'PROFILES — select a row'), classes='title')
                yield DataTable(id='users_table')
            with VerticalScroll(id='actions'):
                with Collapsible(title=tr('УПРАВЛЕНИЕ КЛЮЧОМ', 'SELECTED KEY'), collapsed=False):
                    yield Button(tr('Открыть профиль и ссылку', 'Open profile and link'), id='link', variant='primary')
                    yield Button(tr('Изменить транспорт', 'Change transport'), id='mode', variant='default')
                    yield Button(tr('Удалить ключ', 'Delete key'), id='delete', variant='error')
                    yield Button(tr('Перевыпустить секрет ключа', 'Rotate key secret'), id='rotate-user', variant='error')
                    yield Button(tr('Сбросить трафик ключа', 'Reset key traffic'), id='reset-traffic', variant='warning')
                with Collapsible(title=tr('КЛЮЧИ И ССЫЛКИ', 'KEYS AND LINKS'), collapsed=True):
                    yield Button(tr('Добавить ключ', 'Add key'), id='add', variant='success')
                    yield Button(tr('Показать все ссылки', 'Show all links'), id='links', variant='primary')
                    yield Button(tr('Транспорт для всех ключей', 'Transport for all keys'), id='mode-all')
                with Collapsible(title=tr('ДОМЕН И САЙТ', 'DOMAIN AND WEBSITE'), collapsed=True):
                    yield Button(tr('Сменить домен', 'Change domain'), id='domain', variant='default')
                    yield Button(tr('Редактировать сайт', 'Edit website'), id='site', variant='default')
                    yield Button(tr('Восстановить стандартный сайт', 'Restore default website'), id='restore-site', variant='warning')
                with Collapsible(title=tr('СЕКРЕТЫ И ПУТЬ', 'SECRETS AND PATH'), collapsed=True):
                    yield Button(tr('Перевыпустить все секреты', 'Rotate all key secrets'), id='rotate-secrets', variant='error')
                    yield Button(tr('Случайный путь', 'Generate random path'), id='rotate-path', variant='warning')
                    yield Button(tr('Задать путь', 'Set custom path'), id='set-path', variant='warning')
                with Collapsible(title=tr('СЕРВИС И ОБСЛУЖИВАНИЕ', 'SERVICE AND MAINTENANCE'), collapsed=True):
                    yield Button(tr('Сменить язык', 'Change language'), id='language')
                    yield Button(tr('Состояние и логи', 'Status and logs'), id='diagnostics', variant='default')
                    yield Button(tr('Перезапустить службы', 'Restart services'), id='restart', variant='warning')
                    yield Button(tr('Лимиты и маршруты', 'Limits and routes'), id='limits')
                    yield Button(tr('Монитор процессов', 'Process monitor'), id='monitor')
                    yield Button(tr('Полная ротация: путь и секреты', 'Full rotation: path and secrets'), id='rotate', variant='error')
                with Collapsible(title=tr('ОБНОВЛЕНИЯ', 'UPDATES'), collapsed=True):
                    yield Button(tr('Обновить ядро', 'Update core'), id='update')
                    yield Button(tr('Обновить панель и перезапустить UI', 'Update panel and restart UI'), id='self-update', variant='success')
                    yield Button(tr('Удалить прокси с сервера', 'Uninstall proxy from server'), id='uninstall', variant='error')
        yield Footer()

    def on_resize(self, event) -> None:
        if hasattr(self, 'dashboard_screen'):
            self.dashboard_screen.set_class(event.size.width < 90, 'narrow')

    def on_mount(self) -> None:
        self.dashboard_screen = self.screen
        self.update_title()
        self.dashboard_screen.set_class(self.size.width < 90, 'narrow')
        table = self.dashboard_screen.query_one('#users_table', DataTable)
        table.add_columns('№', tr('Имя', 'Name'), tr('Транспорт', 'Transport'), 'Backend', tr('Онлайн', 'Online'), tr('Трафик', 'Traffic'))
        table.cursor_type, table.zebra_stripes = 'row', True
        self.action_refresh_data()
        self.set_interval(10, self.action_refresh_data)
        self.check_updates()

    def update_title(self):
        try:
            version = VERSION_FILE.read_text(encoding='utf-8').strip()
        except OSError:
            version = ''
        if not version_tuple(version) and version != 'main':
            version = tr('версия неизвестна', 'version unknown')
        self.title = f'{self.TITLE} • {version}'

    @work
    async def check_updates(self):
        panel_result, core_result = await asyncio.gather(asyncio.to_thread(panel_update), asyncio.to_thread(core_update), return_exceptions=True)
        self.update_title()
        tag, current = panel_result if isinstance(panel_result, tuple) else (None, '')
        core = core_result if isinstance(core_result, tuple) else None
        if not tag and not core:
            return
        lines = []
        if tag:
            lines.append(tr(f'Панель: {current or "неизвестная версия"} → {tag}', f'Panel: {current or "unknown version"} → {tag}'))
        if core:
            lines.append(tr(f'Ядро: {core[0][:8]} → {core[1][:8]}', f'Core: {core[0][:8]} → {core[1][:8]}'))
        lines.append(tr('После обновления панель перезапустится.', 'The panel will restart after updating.'))
        button = tr('Обновить всё', 'Update all') if tag and core else tr('Обновить', 'Update')
        result = await self.push_screen_wait(Dialog(tr('Доступны обновления', 'Updates available'), message='\n'.join(lines), confirm=button, cancel=tr('Позже', 'Later')))
        if result is not None:
            if self.busy:
                self.notify(tr('Дождитесь завершения операции и обновите вручную', 'Wait for the operation to finish, then update manually'), severity='warning')
            else:
                commands = ([[CLI_BIN, '--update']] if core else []) + ([[CLI_BIN, '--self-update', tag]] if tag else [])
                self.run_command(tr('Обновление', 'Updating'), commands[0], additional_commands=commands[1:])

    def action_refresh_data(self) -> None:
        table = self.dashboard_screen.query_one('#users_table', DataTable)
        cursor = table.cursor_row
        try:
            profiles = json.loads(PROFILES_FILE.read_text(encoding='utf-8'))['profiles']
            if not isinstance(profiles, list):
                raise ValueError(tr('profiles должен быть списком', 'profiles must be a list'))
            self.profiles = profiles
            table.clear()
            for index, profile in enumerate(profiles, 1):
                online, traffic = self.profile_metrics.get(profile.get('name', ''), (None, None))
                table.add_row(str(index), str(profile.get('name', '')), str(profile.get('carrier_mode', 'https')), str(profile.get('backend', '')), f'~{online}' if online is not None else '—', format_size(traffic) if traffic is not None else '—')
            if profiles:
                table.move_cursor(row=min(cursor, len(profiles) - 1))
            self.dashboard_screen.query_one('#status', Static).update(tr(f'Профилей: {len(profiles)} • F5 — обновить', f'Profiles: {len(profiles)} • F5 — refresh') + (tr(' • Выполняется операция...', ' • Operation in progress...') if self.busy else ''))
            if not self.metrics_busy:
                self.refresh_metrics([dict(profile) for profile in profiles])
        except (OSError, ValueError, KeyError, TypeError) as exc:
            self.profiles = []
            table.clear()
            self.dashboard_screen.query_one('#status', Static).update(tr(f'Не удалось прочитать профили: {exc}', f'Could not read profiles: {exc}'))

    @work(group='metrics')
    async def refresh_metrics(self, profiles):
        self.metrics_busy = True
        try:
            summary, metrics = await asyncio.to_thread(collect_server_metrics, profiles)
            self.dashboard_screen.query_one('#server-metrics', Static).update(summary)
            self.profile_metrics = metrics
            table = self.dashboard_screen.query_one('#users_table', DataTable)
            for row, profile in enumerate(self.profiles):
                online, traffic = metrics.get(profile.get('name', ''), (None, None))
                table.update_cell_at((row, 4), f'~{online}' if online is not None else '—', update_width=True)
                table.update_cell_at((row, 5), format_size(traffic) if traffic is not None else '—', update_width=True)
        except Exception:
            self.dashboard_screen.query_one('#server-metrics', Static).update(tr('Сведения о сервере недоступны', 'Server information unavailable'))
        finally:
            self.metrics_busy = False

    def selected(self):
        row = self.dashboard_screen.query_one('#users_table', DataTable).cursor_row
        if not self.profiles or row >= len(self.profiles):
            self.notify(tr('Выберите профиль в таблице', 'Select a profile in the table'), severity='warning')
            return None
        return self.profiles[row]

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id != 'users_table':
            return
        row = event.cursor_row
        if row < 0 or row >= len(self.profiles):
            return
        self.open_profile(self.profiles[row])

    @work
    async def open_profile(self, profile):
        try:
            config = json.loads(CONFIG_FILE.read_text(encoding='utf-8'))
            link = make_link(profile, config)
            error = ''
        except (OSError, ValueError, KeyError, TypeError) as exc:
            link, error = '', str(exc)
        statistics = await asyncio.to_thread(profile_statistics, dict(profile))
        self.push_screen(ProfileDialog(profile, link, error, statistics))

    @work
    async def on_button_pressed(self, event: Button.Pressed) -> None:
        key = event.button.id
        if self.busy:
            self.notify(tr('Дождитесь завершения операции', 'Wait for the operation to finish'), severity='warning')
            return
        if key in ('link', 'links'):
            selected = self.selected() if key == 'link' else None
            if key == 'link' and selected is None:
                return
            if selected is not None:
                self.open_profile(selected)
                return
            try:
                config = json.loads(CONFIG_FILE.read_text(encoding='utf-8'))
                profiles = [selected] if selected else self.profiles
                if not profiles:
                    raise ValueError(tr('Нет профилей', 'No profiles'))
                text = '\n\n'.join((p['name'] + '\n' if key == 'links' else '') + make_link(p, config) for p in profiles)
                self.push_screen(TextDialog(tr('Ссылки для подключения', 'Connection links'), text, copy=True))
            except (OSError, ValueError, KeyError, TypeError) as exc:
                self.notify(str(exc), severity='error')
        elif key == 'add':
            values = await self.push_screen_wait(Dialog(tr('Новый ключ', 'New key'), [('name', tr('Имя: латинские буквы, цифры, _ и -', 'Name: Latin letters, digits, _ and -'), '', None), ('mode', tr('Транспорт', 'Transport'), 'websocket-lanes', MODES)]))
            if values is not None:
                if not re.fullmatch(r'[A-Za-z0-9_-]+', values['name']):
                    self.notify(tr('Введите корректное имя', 'Enter a valid name'), severity='error'); return
                self.run_command(tr('Создание ключа', 'Creating key'), [CLI_BIN, 'add', values['name'], values['mode']])
        elif key in ('delete', 'mode', 'rotate-user', 'reset-traffic'):
            profile = self.selected()
            if not profile: return
            name = profile['name']
            if key == 'delete':
                values = await self.push_screen_wait(Dialog(tr('Удалить ключ?', 'Delete key?'), message=tr(f'Ключ {name} будет удалён, его ссылка перестанет работать.', f'Key {name} will be deleted and its link will stop working.'), confirm=tr('Удалить', 'Delete')))
                if values is not None: self.run_command(tr('Удаление ключа', 'Deleting key'), [CLI_BIN, 'del', name], 'yes\n')
            elif key == 'mode':
                current = profile.get('carrier_mode', 'https')
                values = await self.push_screen_wait(Dialog(tr('Транспорт: ', 'Transport: ') + name, [('mode', tr('Режим', 'Mode'), current if current in MODES else 'https', MODES)]))
                if values is not None: self.run_command(tr('Изменение транспорта', 'Changing transport'), [CLI_BIN, 'mode', name, values['mode']])
            else:
                rotate = key == 'rotate-user'
                message = tr('Старая ссылка перестанет работать.', 'The old link will stop working.') if rotate else tr('Статистика трафика будет сброшена.', 'Traffic statistics will be reset.')
                values = await self.push_screen_wait(Dialog(name, message=message, confirm=tr('Продолжить', 'Continue')))
                if values is not None:
                    self.run_command(tr('Обновление ключа', 'Updating key'), [CLI_BIN, 'ui-rotate-user' if rotate else 'ui-reset-traffic', name], 'yes\n' if rotate else '')
        elif key == 'mode-all':
            values = await self.push_screen_wait(Dialog(tr('Изменить транспорт для всех ключей', 'Change transport for all keys'), [('mode', tr('Режим', 'Mode'), 'https', MODES)]))
            if values is not None: self.run_command(tr('Изменение транспорта', 'Changing transport'), [CLI_BIN, 'mode', 'all', values['mode']])
        elif key in ('rotate-secrets', 'rotate-path', 'set-path'):
            fields = [('path', tr('Новый путь без слешей (пусто — корень)', 'New path without slashes (empty for root)'), '', None)] if key == 'set-path' else []
            values = await self.push_screen_wait(Dialog(tr('Изменение секретов и пути', 'Change secrets and path'), fields, tr('Старые ссылки перестанут работать.', 'Old links will stop working.'), tr('Продолжить', 'Continue')))
            if values is not None:
                path = values.get('path', '')
                if key == 'set-path' and not re.fullmatch(r'[A-Za-z0-9_-]*', path):
                    self.notify(tr('Путь должен содержать только латинские буквы, цифры, _ и -', 'Path must contain only Latin letters, digits, _ and -'), severity='error')
                    return
                cmd = {'rotate-secrets': 'ui-rotate-secrets', 'rotate-path': 'ui-rotate-path', 'set-path': 'ui-set-path'}[key]
                self.run_command(tr('Изменение секретов и пути', 'Change secrets and path'), [CLI_BIN, cmd] + ([path] if key == 'set-path' else []), 'yes\n')
        elif key == 'limits':
            try:
                config = json.loads(CONFIG_FILE.read_text(encoding='utf-8'))
                env_text = MTPROXY_ENV.read_text(encoding='utf-8')
                env_values = dict(line.split('=', 1) for line in env_text.splitlines() if '=' in line and not line.lstrip().startswith('#'))
                workers, conns = env_values.get('MTPROXY_WORKERS', '1'), env_values.get('MTPROXY_MAX_CONNECTIONS', '4096')
                routes = config.get('static_routes', 'exact')
                values = await self.push_screen_wait(Dialog(tr('Лимиты и маршруты', 'Limits and routes'), [('workers', tr('Воркеры MTProxy', 'MTProxy workers'), workers, None), ('conns', tr('Макс. соединений', 'Max connections'), conns, None), ('routes', tr('Маршрутизация статики', 'Static routing'), routes if routes in ('exact', 'legacy') else 'exact', ('exact', 'legacy'))]))
                if values is not None:
                    if not all(re.fullmatch(r'[1-9][0-9]*', values[field]) for field in ('workers', 'conns')):
                        self.notify(tr('Введите положительные целые числа', 'Enter positive integers'), severity='error'); return
                    self.run_command(tr('Лимиты и маршруты', 'Limits and routes'), [CLI_BIN, 'ui-limits', values['workers'], values['conns'], values['routes']])
            except (OSError, ValueError, TypeError) as exc:
                self.notify(str(exc), severity='error')
        elif key == 'domain':
            values = await self.push_screen_wait(Dialog(tr('Смена домена', 'Change domain'), [('host', tr('Новый домен', 'New domain'), '', None), ('email', tr('Email для сертификата (необязательно)', 'Certificate email (optional)'), '', None)], tr('Ссылки изменятся. Проверьте DNS и доступность портов 80 и 443.', 'Links will change. Check DNS and access to ports 80 and 443.'), tr('Продолжить', 'Continue')))
            if values is not None and values['host'].strip():
                self.run_command(tr('Смена домена', 'Change domain'), [CLI_BIN, 'domain', values['host'].strip()], values['email'].strip() + '\nyes\n')
        elif key in ('rotate', 'restart', 'update', 'self-update'):
            descriptions = {'rotate': tr('Все старые ссылки перестанут работать.', 'All old links will stop working.'), 'restart': tr('Соединения могут временно прерваться.', 'Connections may be temporarily interrupted.'), 'update': tr('Будет обновлено ядро прокси.', 'The proxy core will be updated.'), 'self-update': tr('После обновления интерфейс перезапустится автоматически.', 'The interface will restart automatically after the update.')}
            values = await self.push_screen_wait(Dialog(event.button.label.plain, message=descriptions[key], confirm=tr('Продолжить', 'Continue')))
            if values is not None:
                if key == 'restart': self.run_command(tr('Перезапуск служб', 'Restarting services'), ['systemctl', 'restart', 'tproxy-server', 'mtproxy', 'caddy'])
                else: self.run_command(event.button.label.plain, [CLI_BIN, {'rotate': '--rotate', 'update': '--update', 'self-update': '--self-update'}[key]], 'yes\n' if key == 'rotate' else '')
        elif key == 'uninstall':
            message = tr('Будут удалены прокси, ключи, статистика, настройки и сайт. Службы остановятся, ссылки перестанут работать. Действие необратимо. Конфигурация Caddy будет восстановлена из резервной копии, если она не изменялась после установки; изменённые файлы и общие компоненты сохранятся. Введите DELETE для подтверждения.', 'The proxy, keys, statistics, settings and website will be deleted. Services will stop and links will stop working. This cannot be undone. The previous Caddy configuration will be restored if the installed files are unchanged; modified files and shared components will be retained. Type DELETE to confirm.')
            values = await self.push_screen_wait(Dialog(tr('Полное удаление прокси', 'Uninstall proxy'), [('confirmation', tr('Введите DELETE', 'Type DELETE'), '', None)], message, tr('Удалить', 'Uninstall')))
            if values is not None:
                if values['confirmation'] != 'DELETE':
                    self.notify(tr('Подтверждение не совпадает. Удаление отменено.', 'Confirmation did not match. Uninstall cancelled.'), severity='warning')
                    return
                self.run_command(tr('Удаление прокси', 'Uninstalling proxy'), [CLI_BIN, 'ui-uninstall'], 'DELETE\n')
        elif key == 'language':
            values = await self.push_screen_wait(Dialog(tr('Язык панели', 'Panel language'), [('language', tr('Выберите язык', 'Select language'), LANG, ('ru', 'en'))], tr('Интерфейс перезапустится на выбранном языке.', 'The interface will restart in the selected language.')))
            if values is not None:
                language = values['language']
                try:
                    LANG_FILE.parent.mkdir(parents=True, exist_ok=True)
                    LANG_FILE.write_text(language + '\n', encoding='utf-8')
                    os.environ['PROXY_LANG'] = language
                    os.execv(sys.executable, [sys.executable, str(Path(__file__).resolve())])
                except OSError as exc:
                    self.notify(tr(f'Не удалось сохранить язык или перезапустить панель: {exc}', f'Could not save the language or restart the panel: {exc}'), severity='error')
        elif key == 'diagnostics':
            self.run_command(tr('Состояние и логи', 'Status and logs'), [CLI_BIN, 'ui-diagnostics'])
        elif key == 'monitor':
            self.run_command(tr('Монитор процессов', 'Process monitor'), ['top', '-b', '-n', '1'])
        elif key == 'restore-site':
            values = await self.push_screen_wait(Dialog(tr('Восстановить сайт?', 'Restore website?'), message=tr('Текущий HTML будет заменён стандартной заглушкой.', 'The current HTML will be replaced with the default placeholder.'), confirm=tr('Восстановить', 'Restore')))
            if values is not None:
                self.run_command(tr('Восстановление сайта', 'Restoring website'), [CLI_BIN, 'ui-restore-site'], 'yes\n')
        elif key == 'site':
            try:
                content = SITE_FILE.read_text(encoding='utf-8')
                edited = await self.push_screen_wait(TextDialog(tr('Сайт-заглушка: HTML', 'Placeholder website: HTML'), content, editable=True))
                if edited is not None and edited != content:
                    SITE_FILE.write_text(edited, encoding='utf-8')
                    self.notify(tr('Сайт сохранён. Перезапуск служб…', 'Website saved. Restarting services…'))
                    self.run_command(tr('Применение сайта', 'Applying website'), ['systemctl', 'restart', 'tproxy-server', 'mtproxy', 'caddy'])
                elif edited is not None:
                    self.notify(tr('Изменений нет', 'No changes'))
            except (OSError, UnicodeError) as exc:
                self.notify(str(exc), severity='error')

    @work(exclusive=True)
    async def run_command(self, title, command, input_text='', additional_commands=()):
        self.busy = True
        self.action_refresh_data()
        try:
            env = dict(os.environ, PROXY_LANG=LANG, NO_COLOR='1')
            text = ''
            completed_update = False
            for index, step in enumerate([command, *additional_commands]):
                process = await asyncio.create_subprocess_exec(*step, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, env=env)
                output, _ = await process.communicate(input_text.encode() if index == 0 else b'')
                text += ANSI.sub('', output.decode('utf-8', errors='replace')).strip()
                text += tr(f'\n\nКод завершения: {process.returncode}\n\n', f'\n\nExit code: {process.returncode}\n\n')
                if process.returncode != 0:
                    break
                if step[:2] in ([CLI_BIN, '--self-update'], [CLI_BIN, '--update']):
                    completed_update = True
            if command[1:2] == ['domain'] and ('отменена' in text.lower() or 'cancelled' in text.lower()):
                text += tr('\nПроверьте DNS: при несовпадении адресов операция отменяется.', '\nCheck DNS: the operation is cancelled if addresses do not match.')
            if completed_update and process.returncode != 0:
                text += tr('\nПредыдущее обновление завершилось, следующее не удалось. Перезапустите панель и повторите обновление.', '\nAn earlier update completed, but the next one failed. Restart the panel and retry the update.')
            if completed_update and process.returncode == 0:
                self.notify(tr('Обновление завершено. Перезапуск панели…', 'Update complete. Restarting the panel…'))
                await asyncio.sleep(1)
                os.execv(sys.executable, [sys.executable, str(Path(__file__).resolve())])
            if command[:2] == [CLI_BIN, 'ui-uninstall'] and process.returncode == 0:
                await self.push_screen_wait(TextDialog(title, text, copy=True))
                self.exit()
                return
            self.push_screen(TextDialog(title, text or tr('Готово', 'Done'), copy=True))
        except OSError as exc:
            self.notify(tr(f'Не удалось запустить операцию: {exc}', f'Could not start operation: {exc}'), severity='error')
        finally:
            self.busy = False
            self.action_refresh_data()


if __name__ == '__main__':
    TProxyDashboard().run()
