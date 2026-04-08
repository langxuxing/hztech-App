# -*- coding: utf-8 -*-
"""网页测试：Flutter Web 壳、/res/bg、APK 下载。"""
from __future__ import annotations


class TestIndexFlutterWeb:
    """GET / — Flutter Web 或「未构建」提示页"""

    def test_index_200(self, client):
        r = client.get("/")
        assert r.status_code == 200
        text = r.get_data(as_text=True)
        # 已构建：index.html 含 flutter / main.dart.js；未构建：服务端提示页
        assert (
            "flutter" in text.lower()
            or "main.dart" in text
            or "Flutter Web" in text
            or "flutter build web" in text
        )

    def test_index_placeholder_or_flutter(self, client):
        r = client.get("/")
        assert r.status_code == 200
        text = r.get_data(as_text=True)
        assert "/api/" in text or "flutter" in text.lower()


class TestSpaFallback:
    """BaasAPI（main.py）不提供 Flutter Web 子路径；前端路由由 serve_web_static 托管。"""

    def test_dashboard_path_not_on_api_server(self, client):
        r = client.get("/dashboard")
        assert r.status_code == 404


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
        # 若项目中有 apk/hztech-app-release.apk 则 200
        r = client.get("/download/apk/hztech-app-release.apk")
        if r.status_code == 200:
            # APK 可能是 application/vnd.android.package-archive 或 octet-stream
            assert r.content_type and (
                "octet-stream" in r.content_type
                or "android" in r.content_type
                or "package" in r.content_type
            )
        else:
            assert r.status_code == 404
