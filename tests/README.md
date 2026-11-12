自动测试：`bash tests/unit.sh`、`bash tests/transaction.sh` 和 `python3 tests/catalog.py`。

`tests/integration.sh` 会实际安装并启动测试服务，仅在可丢弃的 Linux/systemd 测试机器上以 root 执行。
