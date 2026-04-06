"""GET /api/app-version 无需登录，返回 android/ios 版本字段。"""


def test_app_version_public(client):
    r = client.get("/api/app-version")
    assert r.status_code == 200
    data = r.get_json()
    assert data.get("success") is True
    assert "android" in data
    assert "ios" in data
    assert "min_version" in data["android"]
    assert "latest_version" in data["android"]
    assert "apk_filename" in data["android"]
    assert "min_version" in data["ios"]
    assert "latest_version" in data["ios"]
    assert "store_url" in data["ios"]
