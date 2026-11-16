#!/usr/bin/env python3
<<<<<<< HEAD
"""Terminal dashboard; management operations are delegated to the existing CLI."""
import json
import subprocess
from pathlib import Path

from textual.app import App, ComposeResult
from textual.containers import Horizontal, VerticalScroll
from textual.widgets import Button, DataTable, Footer, Header, Label, Static

PROFILES_FILE = Path('/etc/tproxy-server/profiles.json')
CLI_BIN = '/usr/local/bin/proxy'


class TProxyDashboard(App):
    TITLE = 'TProxy • Центр управления'
    CSS = '''
    Screen { layout: vertical; }
    #content { height: 1fr; layout: horizontal; }
    #profiles { width: 2fr; border: round $primary; padding: 0 1; }
    #actions { width: 1fr; min-width: 30; border: round $accent; padding: 0 1; }
    .title { text-style: bold; color: $accent; padding: 1 0; }
    #status { height: auto; padding: 0 1; }
    DataTable { height: 1fr; }
    Button { width: 100%; margin-bottom: 1; }
    .narrow #content { layout: vertical; }
    .narrow #profiles { width: 100%; height: 40%; }
    .narrow #actions { width: 100%; height: 60%; }
    '''
    BINDINGS = [('f5', 'refresh_data', 'Обновить'), ('q', 'quit', 'Выход')]

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield Static('Профили и действия управления', id='status')
        with Horizontal(id='content'):
            with VerticalScroll(id='profiles'):
                yield Label('ПРОФИЛИ', classes='title')
                yield DataTable(id='users_table')
            with VerticalScroll(id='actions'):
                yield Label('УПРАВЛЕНИЕ', classes='title')
                yield Button('Ключи, ссылки и статистика', id='users', variant='primary')
                yield Button('Добавить ключ', id='add')
                yield Button('Удалить ключ', id='del')
                yield Button('Изменить транспорт', id='mode')
                yield Button('Изменить домен', id='domain')
                yield Button('Сайт-заглушка', id='site')
                yield Button('Монитор ресурсов', id='htop')
                yield Label('ОБСЛУЖИВАНИЕ', classes='title')
                yield Button('Обновить ядро', id='update', variant='warning')
                yield Button('Обновить панель', id='self-update', variant='success')
                yield Button('Все настройки и диагностика', id='menu')
        yield Footer()

    def on_resize(self, event) -> None:
        self.screen.set_class(event.size.width < 90, "narrow")

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns('№', 'Имя', 'Транспорт', 'Backend')
        table.cursor_type = 'row'
        table.zebra_stripes = True
        self.action_refresh_data()
        self.set_interval(10, self.action_refresh_data)

    def action_refresh_data(self) -> None:
        table = self.query_one(DataTable)
        cursor = table.cursor_row
        try:
            with PROFILES_FILE.open(encoding='utf-8') as stream:
                data = json.load(stream)
            profiles = data['profiles']
            if not isinstance(profiles, list):
                raise ValueError('profiles должен быть списком')
            table.clear()
            for index, profile in enumerate(profiles, 1):
                table.add_row(str(index), str(profile.get('name', '')), str(profile.get('carrier_mode', 'https')), str(profile.get('backend', '')))
            if profiles:
                table.move_cursor(row=min(cursor, len(profiles) - 1))
            self.query_one('#status', Static).update(f'Профилей: {len(profiles)}  •  F5 — обновить  •  Выберите действие справа')
        except (OSError, ValueError, KeyError, TypeError) as exc:
            self.query_one('#status', Static).update(f'Не удалось прочитать профили: {exc}')

    def on_button_pressed(self, event: Button.Pressed) -> None:
        command = event.button.id
        if not command:
            return
        # The CLI owns prompts, confirmations, and error reporting. Never feed
        # automatic answers into destructive or network operations.
        with self.suspend():
            try:
                result = subprocess.run([CLI_BIN, command], check=False)
                print(f'\nКоманда завершена (код {result.returncode}).')
            except OSError as exc:
                print(f'\nНе удалось запустить CLI: {exc}')
            input('Нажмите Enter для возврата в панель...')
        self.action_refresh_data()


if __name__ == '__main__':
=======
# -*- coding: utf-8 -*-

import json
import os
import subprocess
from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import Header, Footer, DataTable, RichLog, Label, Input, Button, Select
from textual.screen import ModalScreen
from textual import work

PROFILES_FILE = "/etc/tproxy-server/profiles.json"
CLI_BIN = "/usr/local/bin/proxy"

class ActionInput(ModalScreen[str]):
    CSS = """
    ActionInput {
        align: center middle;
    }
    #dialog {
        padding: 1 2;
        width: 60;
        height: auto;
        border: round #00bfff;
        background: $surface;
    }
    """
    
    def __init__(self, prompt_text: str, placeholder: str = ""):
        super().__init__()
        self.prompt_text = prompt_text
        self.placeholder = placeholder

    def compose(self) -> ComposeResult:
        with Vertical(id="dialog"):
            yield Label(self.prompt_text)
            yield Input(id="user_input", placeholder=self.placeholder)
            with Horizontal():
                yield Button("Отмена", id="cancel", variant="error")
                yield Button("Подтвердить", id="ok", variant="success")

    def on_mount(self) -> None:
        self.query_one(Input).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "ok":
            self.dismiss(self.query_one(Input).value)
        else:
            self.dismiss("")

class ModeSelect(ModalScreen[tuple]):
    CSS = """
    ModeSelect {
        align: center middle;
    }
    #dialog {
        padding: 1 2;
        width: 60;
        height: auto;
        border: round #32cd32;
        background: $surface;
    }
    """
    
    def compose(self) -> ComposeResult:
        with Vertical(id="dialog"):
            yield Label("Изменение транспорта (Mode)")
            yield Input(id="target_name", placeholder="Имя ключа (или all)")
            yield Select([
                ("websocket-lanes", "websocket-lanes"),
                ("websocket", "websocket"),
                ("https-lanes", "https-lanes"),
                ("https", "https")
            ], id="mode_select", prompt="Выбор транспорта")
            with Horizontal():
                yield Button("Отмена", id="cancel", variant="error")
                yield Button("Применить", id="ok", variant="success")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "ok":
            target = self.query_one("#target_name", Input).value
            mode = self.query_one("#mode_select", Select).value
            if target and mode:
                self.dismiss((target, mode))
            else:
                self.dismiss(None)
        else:
            self.dismiss(None)

class TProxyDashboard(App):
    TITLE = "TG-Proxy Control Center"
    
    CSS = """
    Screen { layout: vertical; }
    #main_grid { layout: horizontal; height: 1fr; }
    #left_panel { width: 65%; border: round #00bfff; padding: 0 1; }
    #right_panel { width: 35%; border: round #32cd32; padding: 0 1; }
    .panel_title { text-align: center; text-style: bold; color: #f0e68c; padding-bottom: 1; }
    DataTable { height: 1fr; }
    RichLog { height: 1fr; background: $surface; overflow-x: hidden; }
    """
    
    BINDINGS = [
        ("a", "add_user", "Добавить"),
        ("d", "del_user", "Удалить"),
        ("m", "change_mode", "Транспорт"),
        ("c", "change_domain", "Домен"),
        ("s", "rotate_secrets", "Ротация"),
        ("u", "update_system", "Обновить"),
        ("n", "nano_site", "Сайт (Nano)"),
        ("h", "htop", "Htop"),
        ("l", "check_logs", "Логи"),
        ("r", "restart_services", "Рестарт"),
        ("q", "quit", "Выход"),
    ]

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Horizontal(id="main_grid"):
            with Vertical(id="left_panel"):
                yield Label("[ ПОЛЬЗОВАТЕЛИ И СТАТУС ]", classes="panel_title")
                yield DataTable(id="users_table")
            with Vertical(id="right_panel"):
                yield Label("[ СИСТЕМНЫЙ ТЕРМИНАЛ ]", classes="panel_title")
                yield RichLog(id="sys_log", markup=True)
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns("ID", "KEY", "MODE", "BACKEND", "SECRET")
        table.cursor_type = "row"
        table.zebra_stripes = True
        
        self.log_msg("[b][green][+][/] Интерфейс запущен. Связь с ядром установлена.[/]")
        self.action_refresh_data()
        self.set_interval(4.0, self.action_refresh_data)

    def log_msg(self, msg: str) -> None:
        self.query_one(RichLog).write(msg)

    def action_refresh_data(self) -> None:
        table = self.query_one(DataTable)
        current_cursor = table.cursor_coordinate
        table.clear()
        
        if not os.path.exists(PROFILES_FILE):
            self.log_msg(f"[red][!][/] Файл {PROFILES_FILE} не найден.")
            return
            
        try:
            with open(PROFILES_FILE, 'r', encoding='utf-8') as f:
                data = json.load(f)
            
            for idx, p in enumerate(data.get("profiles", []), 1):
                table.add_row(
                    str(idx), 
                    p.get("name", ""), 
                    p.get("carrier_mode", ""), 
                    p.get("backend", ""), 
                    p.get("secret", "")[:10] + "..."
                )
            if current_cursor and current_cursor.row < len(table.rows):
                table.move_cursor(row=current_cursor.row)
        except Exception as e:
            self.log_msg(f"[red][!][/] Ошибка БД: {e}")

    def run_backend(self, args: list, input_data: str = None) -> None:
        self.log_msg(f"\n[cyan][*][/] Исполнение: sudo proxy {' '.join(args)}")
        try:
            res = subprocess.run(
                ["sudo", CLI_BIN] + args, 
                input=input_data, 
                text=True, 
                capture_output=True
            )
            if res.stdout:
                clean_out = res.stdout.replace('\033[0m', '').replace('\033[1;32m', '').replace('\033[1;31m', '').replace('\033[1;33m', '').replace('\033[1;36m', '').replace('\033[1m', '')
                self.log_msg(clean_out.strip())
            if res.stderr:
                self.log_msg(f"[red]{res.stderr.strip()}[/]")
            self.action_refresh_data()
        except Exception as e:
            self.log_msg(f"[red][!][/] Сбой ядра: {e}")

    @work
    async def action_run_interactive(self, cmd: str) -> None:
        self.log_msg(f"[yellow][*][/] Приостановка интерфейса для вызова {cmd}...")
        with self.suspend():
            subprocess.run(["sudo", CLI_BIN, cmd])
        self.log_msg(f"[green][+][/] Возврат в графический режим.")
        self.action_refresh_data()

    @work
    async def action_add_user(self) -> None:
        name = await self.push_screen_wait(ActionInput("ИМЯ нового ключа (лат/цифры):"))
        if name:
            self.run_backend(["add", name, "websocket-lanes"])

    @work
    async def action_del_user(self) -> None:
        name = await self.push_screen_wait(ActionInput("Удаление: Введите точное имя ключа:"))
        if name:
            self.run_backend(["del", name], input_data="yes\n")

    @work
    async def action_change_mode(self) -> None:
        result = await self.push_screen_wait(ModeSelect())
        if result:
            target, mode = result
            self.run_backend(["mode", target, mode])

    @work
    async def action_change_domain(self) -> None:
        domain = await self.push_screen_wait(ActionInput("Новый домен (получит SSL):", "proxy.com"))
        if domain:
            self.run_backend(["domain", domain], input_data="yes\n")

    @work
    async def action_rotate_secrets(self) -> None:
        confirm = await self.push_screen_wait(ActionInput("Сгенерировать новые секреты и пути? (введите yes):"))
        if confirm and confirm.lower() in ("yes", "y", "да"):
            self.run_backend(["rotate"], input_data="yes\n")

    @work
    async def action_update_system(self) -> None:
        confirm = await self.push_screen_wait(ActionInput("Обновить ядро tproxy-server? (yes):"))
        if confirm and confirm.lower() in ("yes", "y", "да"):
            self.run_backend(["update"])

    def action_nano_site(self) -> None:
        self.action_run_interactive("site")

    def action_htop(self) -> None:
        self.action_run_interactive("htop")

    def action_restart_services(self) -> None:
        self.log_msg("[yellow][*][/] Перезапуск Caddy, Tproxy и MTProxy...")
        subprocess.run(["sudo", "systemctl", "restart", "caddy", "tproxy-server", "mtproxy"])
        self.log_msg("[green][+][/] Сервисы успешно перезапущены.")

    def action_check_logs(self) -> None:
        self.log_msg("\n[cyan][*][/] Чтение логов (journalctl)...")
        res = subprocess.run(["sudo", "journalctl", "-u", "tproxy-server", "-n", "30", "--no-pager"], capture_output=True, text=True)
        self.log_msg(res.stdout)

if __name__ == "__main__":
>>>>>>> 4216e8b08e68433b720fca20f94a2a20c92df413
    TProxyDashboard().run()
