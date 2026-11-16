#!/usr/bin/env python3
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
    TProxyDashboard().run()
