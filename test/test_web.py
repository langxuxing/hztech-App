# -*- coding: utf-8 -*-
"""网页测试：首页、dashboard、res/bg、download。"""
from __future__ import annotations


class TestIndex:
    """GET / 落地页"""

    def test_index_200(self, client):
        r = client.get("/")
        assert r.status_code == 200
        text = r.get_data(as_text=True)
        assert "禾正量化" in text or "HZTech" in text

    def test_index_has_download_link(self, client):
        r = client.get("/")
        assert r.status_code == 200
        assert "下载" in r.get_data(as_text=True)


class TestDashboard:
    """GET /dashboard"""

    def test_dashboard_200(self, client):
        r = client.get("/dashboard")
        assert r.status_code == 200
        text = r.get_data(as_text=True)
        assert "仪表盘" in text or "应用下载" in text

    def test_dashboard_has_back_link(self, client):
        r = client.get("/dashboard")
        assert r.status_code == 200
        text = r.get_data(as_text=True)
        assert "返回首页" in text or 'href="/"' in text


class TestResBg:
    """GET /res/bg 背景图"""

    def test_res_bg(self, client):
        r = client.get("/res/bg")
        # 有图 200 image/png，无图 404
        assert r.status_code in (200, 404)
        if r.status_code == 200:
            assert r.content_type and "image" in r.content_type


class TestDownloadApk:
    """GET /download/apk/<filename>"""

    def test_download_invalid_filename_400(self, client):
        r = client.get("/download/apk/notanapk.txt")
        assert r.status_code == 400

    def test_download_nonexistent_404(self, client):
        r = client.get("/download/apk/nonexistent.apk")
        assert r.status_code == 404

    def test_download_apk_exists(self, client):
        # 若项目中有 apk/禾正量化-release.apk 则 200
        r = client.get("/download/apk/禾正量化-release.apk")
        if r.status_code == 200:
            # APK 可能是 application/vnd.android.package-archive 或 octet-stream
            assert r.content_type and (
                "octet-stream" in r.content_type
                or "android" in r.content_type
                or "package" in r.content_type
            )
        else:
            assert r.status_code == 404
