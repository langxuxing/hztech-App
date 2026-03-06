# 后台 API 与网页测试

从项目根目录执行（需先 pip install -r server/requirements.txt）：

  PYTHONPATH=server pytest test/ -v

仅运行 API 测试：  PYTHONPATH=server pytest test/test_api.py -v
仅运行网页测试：  PYTHONPATH=server pytest test/test_web.py -v

测试使用临时 SQLite 数据库，不会修改 server/data.db。
