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
from pathlib import Path
from urllib.parse import quote

from textual import work
from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, DataTable, Footer, Header, Input, Label, Select, Static, TextArea

PROFILES_FILE = Path('/etc/tproxy-server/profiles.json')
CONFIG_FILE = Path('/etc/tproxy-server/config.json')
SITE_FILE = Path('/srv/tproxy-site/index.html')
TRAFFIC_FILE = Path('/etc/tproxy-server/traffic_stats.json')
CLI_BIN = '/usr/local/bin/tg-proxy'
MODES = ('https', 'https-lanes', 'websocket', 'websocket-lanes')
ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')


def format_size(value):
    for unit in ('Б', 'КиБ', 'МиБ', 'ГиБ', 'ТиБ'):
        if value < 1024 or unit == 'ТиБ':
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
        states.append(f'{label}: {"работает" if state and state.strip() == "active" else "неизвестно/остановлен"}')

    connections = []
    for profile in profiles:
        port = str(profile.get('backend', '')).rsplit(':', 1)[-1]
        if not port.isdigit():
            connections = None
            break
        output = run('ss', '-Htan', 'state', 'established', f'( dport = :{port} )')
        if output is None:
            connections = None
            break
        connections.append(len(output.splitlines()))
    if connections is None:
        online = '—'
    else:
        online = f'~{sum((count + 5) // 6 for count in connections)} чел. ({sum(connections)} соед.)'

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
            traffic = sum(int(saved.get(name, {}).get(direction, 0)) for name in names for direction in ('rx', 'tx'))
            for item in json.loads(nft).get('nftables', []):
                rule = item.get('rule', {})
                comment = rule.get('comment', '')
                if (comment.startswith('rx_') or comment.startswith('tx_')) and comment[3:] in names:
                    traffic += sum(int(expr['counter'].get('bytes', 0)) for expr in rule.get('expr', []) if 'counter' in expr)
        except (ValueError, TypeError, AttributeError):
            traffic = None
    return (f'CPU: {cpu} • RAM: {ram} • Диск: {disk_text} • Load: {load}\n'
            f'Онлайн: {online} • Трафик всего: {format_size(traffic) if traffic is not None else "—"} • '
            + '  '.join(states))


def make_link(profile, config):
    host = config.get('public_hostname') or config.get('hostname')
    if not host:
        raise ValueError('Домен не найден в конфигурации')
    path = config.get('base_path') or ''
    secret = profile['secret'].removeprefix('dd')
    if path:
        secret = base64.urlsafe_b64encode(b'\x70' + bytes.fromhex(secret)).decode().rstrip('=')
    server = host + ('/' + path if path else '')
    return 'https://t.me/webproxy?server=' + quote(server, safe='') + '&secret=' + secret


class Dialog(ModalScreen):
    CSS = '''
    Dialog { align: center middle; background: $background 70%; }
    #dialog { width: 76; max-width: 95%; height: auto; max-height: 90%; border: round $accent; background: $surface; padding: 1 2; }
    #dialog-body { height: auto; max-height: 1fr; }
    #dialog-buttons { height: auto; margin-top: 1; }
    #dialog-buttons Button { width: 1fr; margin-right: 1; }
    Input, Select { margin-bottom: 1; }
    '''
    def __init__(self, title, fields=(), message='', confirm='Применить'):
        super().__init__()
        self.title_text, self.fields, self.message, self.confirm = title, fields, message, confirm

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
                yield Button('Отмена', id='cancel')
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
                yield Button('Закрыть', id='close')
                if self.copy:
                    yield Button('Копировать всё', id='copy', variant='primary')
                if self.editable:
                    yield Button('Сохранить', id='save', variant='primary')

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == 'copy':
            self.app.copy_to_clipboard(self.query_one(TextArea).text)
            self.app.notify('Отправлено в буфер обмена терминала')
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

    def __init__(self, profile, link, error=''):
        super().__init__()
        self.profile, self.link, self.error = profile, link, error

    def compose(self) -> ComposeResult:
        with Vertical(id='profile-card'):
            yield Label('Профиль: ' + str(self.profile.get('name', '')), classes='dialog-title')
            with VerticalScroll(id='profile-content'):
                yield Static('Транспорт: ' + str(self.profile.get('carrier_mode', 'https')), markup=False)
                yield Static('Backend: ' + str(self.profile.get('backend', '')), markup=False)
                yield Label('Ссылка для подключения')
                if self.link:
                    yield Input(value=self.link, id='profile-link')
                else:
                    yield Static('Не удалось сформировать ссылку: ' + self.error, markup=False)
            with Horizontal(id='profile-buttons'):
                yield Button('Закрыть', id='profile-close')
                if self.link:
                    yield Button('Копировать ссылку', id='profile-copy', variant='primary')

    def on_button_pressed(self, event: Button.Pressed) -> None:
        event.stop()
        if event.button.id == 'profile-copy':
            self.app.copy_to_clipboard(self.link)
            self.app.notify('Ссылка отправлена в буфер обмена терминала')
        elif event.button.id == 'profile-close':
            self.dismiss()


class TProxyDashboard(App):
    TITLE = 'TG-Proxy • Центр управления'
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
    .section-title { color: $text-muted; text-style: bold; padding: 1 0 0 0; }
    .narrow #content { layout: vertical; }
    .narrow #profiles { width: 100%; height: 40%; }
    .narrow #actions { width: 100%; height: 60%; }
    '''
    BINDINGS = [('f5', 'refresh_data', 'Обновить'), ('q', 'quit', 'Выход')]

    def __init__(self):
        super().__init__()
        self.profiles = []
        self.busy = False
        self.metrics_busy = False

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield Static('Загрузка...', id='status')
        yield Static('Загрузка сведений о сервере...', id='server-metrics', markup=False)
        with Horizontal(id='content'):
            with Vertical(id='profiles'):
                yield Label('ПРОФИЛИ — выберите строку', classes='title')
                yield DataTable(id='users_table')
            with VerticalScroll(id='actions'):
                yield Label('УПРАВЛЕНИЕ ВЫБРАННЫМ КЛЮЧОМ', classes='section-title')
                yield Button('Открыть профиль и ссылку', id='link', variant='primary')
                yield Button('Изменить транспорт', id='mode', variant='default')
                yield Button('Удалить ключ', id='delete', variant='error')
                yield Label('КЛЮЧИ И ССЫЛКИ', classes='section-title')
                yield Button('Добавить ключ', id='add', variant='success')
                yield Button('Показать все ссылки', id='links', variant='primary')
                yield Label('ДОМЕН И САЙТ', classes='section-title')
                yield Button('Сменить домен', id='domain', variant='default')
                yield Button('Редактировать сайт', id='site', variant='default')
                yield Label('СЕРВИС И ОБСЛУЖИВАНИЕ', classes='section-title')
                yield Button('Состояние и логи', id='diagnostics', variant='default')
                yield Button('Перезапустить службы', id='restart', variant='warning')
                yield Button('Полная ротация секретов', id='rotate', variant='warning')
                yield Button('Обновить ядро', id='update', variant='warning')
                yield Button('Обновить панель и перезапустить UI', id='self-update', variant='success')
        yield Footer()

    def on_resize(self, event) -> None:
        self.screen.set_class(event.size.width < 90, 'narrow')

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns('№', 'Имя', 'Транспорт', 'Backend')
        table.cursor_type, table.zebra_stripes = 'row', True
        self.action_refresh_data()
        self.set_interval(10, self.action_refresh_data)

    def action_refresh_data(self) -> None:
        table = self.query_one(DataTable)
        cursor = table.cursor_row
        try:
            profiles = json.loads(PROFILES_FILE.read_text(encoding='utf-8'))['profiles']
            if not isinstance(profiles, list):
                raise ValueError('profiles должен быть списком')
            self.profiles = profiles
            table.clear()
            for index, profile in enumerate(profiles, 1):
                table.add_row(str(index), str(profile.get('name', '')), str(profile.get('carrier_mode', 'https')), str(profile.get('backend', '')))
            if profiles:
                table.move_cursor(row=min(cursor, len(profiles) - 1))
            self.query_one('#status', Static).update(f'Профилей: {len(profiles)} • F5 — обновить' + (' • Выполняется операция...' if self.busy else ''))
            if not self.metrics_busy:
                self.refresh_metrics([dict(profile) for profile in profiles])
        except (OSError, ValueError, KeyError, TypeError) as exc:
            self.profiles = []
            table.clear()
            self.query_one('#status', Static).update(f'Не удалось прочитать профили: {exc}')

    @work(group='metrics')
    async def refresh_metrics(self, profiles):
        self.metrics_busy = True
        try:
            metrics = await asyncio.to_thread(collect_server_metrics, profiles)
            self.query_one('#server-metrics', Static).update(metrics)
        except Exception:
            self.query_one('#server-metrics', Static).update('Сведения о сервере недоступны')
        finally:
            self.metrics_busy = False

    def selected(self):
        row = self.query_one(DataTable).cursor_row
        if not self.profiles or row >= len(self.profiles):
            self.notify('Выберите профиль в таблице', severity='warning')
            return None
        return self.profiles[row]

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id != 'users_table':
            return
        row = event.cursor_row
        if row < 0 or row >= len(self.profiles):
            return
        self.open_profile(self.profiles[row])

    def open_profile(self, profile):
        try:
            config = json.loads(CONFIG_FILE.read_text(encoding='utf-8'))
            link = make_link(profile, config)
            error = ''
        except (OSError, ValueError, KeyError, TypeError) as exc:
            link, error = '', str(exc)
        self.push_screen(ProfileDialog(profile, link, error))

    @work
    async def on_button_pressed(self, event: Button.Pressed) -> None:
        key = event.button.id
        if self.busy:
            self.notify('Дождитесь завершения операции', severity='warning')
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
                    raise ValueError('Нет профилей')
                text = '\n\n'.join((p['name'] + '\n' if key == 'links' else '') + make_link(p, config) for p in profiles)
                self.push_screen(TextDialog('Ссылки для подключения', text, copy=True))
            except (OSError, ValueError, KeyError, TypeError) as exc:
                self.notify(str(exc), severity='error')
        elif key == 'add':
            values = await self.push_screen_wait(Dialog('Новый ключ', [('name', 'Имя: латинские буквы, цифры, _ и -', '', None), ('mode', 'Транспорт', 'websocket-lanes', MODES)]))
            if values is not None:
                if not re.fullmatch(r'[A-Za-z0-9_-]+', values['name']):
                    self.notify('Введите корректное имя', severity='error'); return
                self.run_command('Создание ключа', [CLI_BIN, 'add', values['name'], values['mode']])
        elif key in ('delete', 'mode'):
            profile = self.selected()
            if not profile: return
            name = profile['name']
            if key == 'delete':
                values = await self.push_screen_wait(Dialog('Удалить ключ?', message=f'Ключ {name} будет удалён, его ссылка перестанет работать.', confirm='Удалить'))
                if values is not None: self.run_command('Удаление ключа', [CLI_BIN, 'del', name], 'yes\n')
            else:
                current = profile.get('carrier_mode', 'https')
                values = await self.push_screen_wait(Dialog('Транспорт: ' + name, [('mode', 'Режим', current if current in MODES else 'https', MODES)]))
                if values is not None: self.run_command('Изменение транспорта', [CLI_BIN, 'mode', name, values['mode']])
        elif key == 'domain':
            values = await self.push_screen_wait(Dialog('Смена домена', [('host', 'Новый домен', '', None), ('email', 'Email для сертификата (необязательно)', '', None)], 'Ссылки изменятся. Проверьте DNS и доступность портов 80 и 443.', 'Продолжить'))
            if values is not None and values['host'].strip():
                self.run_command('Смена домена', [CLI_BIN, 'domain', values['host'].strip()], values['email'].strip() + '\nyes\n')
        elif key in ('rotate', 'restart', 'update', 'self-update'):
            descriptions = {'rotate': 'Все старые ссылки перестанут работать.', 'restart': 'Соединения могут временно прерваться.', 'update': 'Будет обновлено ядро прокси.', 'self-update': 'После обновления интерфейс перезапустится автоматически.'}
            values = await self.push_screen_wait(Dialog(event.button.label.plain, message=descriptions[key], confirm='Продолжить'))
            if values is not None:
                if key == 'restart': self.run_command('Перезапуск служб', ['systemctl', 'restart', 'tproxy-server', 'mtproxy', 'caddy'])
                else: self.run_command(event.button.label.plain, [CLI_BIN, {'rotate': '--rotate', 'update': '--update', 'self-update': '--self-update'}[key]], 'yes\n' if key == 'rotate' else '')
        elif key == 'diagnostics':
            self.run_command('Состояние и логи', ['journalctl', '-u', 'tproxy-server', '-u', 'mtproxy', '-u', 'caddy', '--no-pager', '-n', '100'])
        elif key == 'site':
            try:
                content = SITE_FILE.read_text(encoding='utf-8')
                edited = await self.push_screen_wait(TextDialog('Сайт-заглушка: HTML', content, editable=True))
                if edited is not None:
                    SITE_FILE.write_text(edited, encoding='utf-8')
                    self.notify('Сайт сохранён')
            except (OSError, UnicodeError) as exc:
                self.notify(str(exc), severity='error')

    @work(exclusive=True)
    async def run_command(self, title, command, input_text=''):
        self.busy = True
        self.action_refresh_data()
        try:
            env = dict(os.environ, PROXY_LANG='ru', NO_COLOR='1')
            process = await asyncio.create_subprocess_exec(*command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, env=env)
            output, _ = await process.communicate(input_text.encode())
            text = ANSI.sub('', output.decode('utf-8', errors='replace')).strip()
            text += f'\n\nКод завершения: {process.returncode}'
            if title == 'Смена домена' and 'отменена' in text.lower():
                text += '\nПроверьте DNS: при несовпадении адресов операция отменяется.'
            if command == [CLI_BIN, '--self-update'] and process.returncode == 0:
                self.notify('Панель обновлена. Перезапуск интерфейса…')
                await asyncio.sleep(1)
                os.execv(sys.executable, [sys.executable, str(Path(__file__).resolve())])
            self.push_screen(TextDialog(title, text or 'Готово', copy=True))
        except OSError as exc:
            self.notify(f'Не удалось запустить операцию: {exc}', severity='error')
        finally:
            self.busy = False
            self.action_refresh_data()


if __name__ == '__main__':
    TProxyDashboard().run()
