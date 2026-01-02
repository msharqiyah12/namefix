# namefix

A robust bash script for validating and sanitizing filenames to ensure compatibility across Windows, Linux, macOS, and Android. It detects and fixes reserved names, forbidden characters, and other filesystem issues.

## Key Features

- **Cross-Platform Safety**: Detects Windows reserved names (CON, PRN, etc.) and forbidden characters (`< > : " | ? * \ /`).
- **Flexible Modes**: Supports Interactive prompts, Batch processing, and Dry-run previews.
- **Undo Support**: Automatically backs up original filenames, allowing full rollback of changes.
- **Smart Sanitization**: Handles special characters, trailing spaces/dots, and Unicode issues (emojis, zero-width chars).
- **Automation Ready**: Includes JSON output support and silent operation modes.

## Installation

1. Download the script:
   ```bash
   curl -O https://raw.githubusercontent.com/pinkorca/namefix/main/namefix.sh
   ```

2. Make it executable:
   ```bash
   chmod +x namefix.sh
   ```

3. (Optional) Move to your path:
   ```bash
   sudo mv namefix.sh /usr/local/bin/namefix
   ```

## Quick Start

Test a directory for issues (without making changes):
```bash
./namefix.sh /path/to/files
```

Preview what would be renamed:
```bash
./namefix.sh --fix --dry-run /path/to/files
```

## Usage Examples

**Interactive Mode**: Review each change before applying
```bash
./namefix.sh --fix --interactive .
```

**Batch Mode**: Automatically fix all files in a directory (recursive)
```bash
./namefix.sh --fix --batch --recursive ~/Downloads
```

**JSON Output**: Integrate with other scripts or tools
```bash
./namefix.sh --check --json . > report.json
```

**Undo Changes**: Restore filenames from the last operation
```bash
./namefix.sh --undo .
```

## Options

| Option | Description |
|--------|-------------|
| `-c`, `--check` | Check for issues only (Default) |
| `-f`, `--fix` | Sanitise problematic filenames |
| `-u`, `--undo` | Restore original filenames from backup |
| `-d`, `--dry-run` | Preview changes without applying them |
| `-i`, `--interactive` | Prompt for confirmation before each rename |
| `-b`, `--batch` | Apply fixes automatically without prompting |
| `-r`, `--recursive` | Process subdirectories recursively |
| `-j`, `--json` | Output results in JSON format |
| `-v`, `--verbose` | Show detailed output |
| `-q`, `--quiet` | Suppress non-essential output |
| `-s`, `--strategy` | Sanitization strategy: `underscore` (default), `hyphen`, `remove` |

## License

This project is licensed under the [GPL-3.0 License](LICENSE).

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
