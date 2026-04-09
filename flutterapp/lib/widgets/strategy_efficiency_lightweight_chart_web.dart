// Web-only：嵌入 Lightweight Charts（iframe），非 Flutter 插件场景下使用 package:web。
// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart';

import '../api/models.dart';

/// Web：使用 TradingView [Lightweight Charts](https://www.tradingview.com/lightweight-charts/) 展示策略能效。
/// 按日柱：每日波动率%（左上半轴，斜线底纹）分档着色；现金收益率%（左下半轴，网格底纹）分档着色。
/// 策略能效折线（右轴）：单序列展示全部有效点（避免分段线仅 1 个点时不渲染）。
class StrategyEfficiencyLightweightChart extends StatefulWidget {
  const StrategyEfficiencyLightweightChart({
    super.key,
    required this.rows,
    this.height = 420,
  });

  final List<StrategyDailyEfficiencyRow> rows;
  final double height;

  @override
  State<StrategyEfficiencyLightweightChart> createState() =>
      _StrategyEfficiencyLightweightChartState();
}

class _StrategyEfficiencyLightweightChartState
    extends State<StrategyEfficiencyLightweightChart> {
  static int _seq = 0;
  late final String _viewType = 'strategy_eff_lwc_${++_seq}';
  HTMLIFrameElement? _iframe;

  /// Lightweight Charts 的 [time] 仅接受严格 `YYYY-MM-DD` 或 UTC 秒时间戳。
  /// 服务端偶发 `2026-3-1`、`2026-03-1 9` 等会导致整图不渲染；对比图用序号映射故不受影响。
  static int? _utcSecondsForChartTime(String rawDay) {
    final raw = rawDay.trim();
    if (raw.isEmpty) return null;
    final tokens = raw.split(RegExp(r'\s+'));
    var datePart = tokens.first;
    if (datePart.contains('T')) {
      datePart = datePart.split('T').first;
    }
    var hour = 0;
    var minute = 0;
    if (tokens.length >= 2) {
      hour = int.tryParse(tokens[1]) ?? 0;
      if (hour < 0 || hour > 23) hour = 0;
    }
    if (tokens.length >= 3) {
      minute = int.tryParse(tokens[2]) ?? 0;
      if (minute < 0 || minute > 59) minute = 0;
    }
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(datePart);
    if (m == null) return null;
    final y = int.tryParse(m.group(1)!);
    final mo = int.tryParse(m.group(2)!);
    final d = int.tryParse(m.group(3)!);
    if (y == null || mo == null || d == null) return null;
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return DateTime.utc(y, mo, d, hour, minute).millisecondsSinceEpoch ~/
        1000;
  }

  /// 与“效能对比图”同思路：先按日期排序，再用稳定序号生成横轴时间，
  /// 避免将脏日期字符串直接喂给 Lightweight Charts 导致整图不渲染。
  static int _stableUtcSecondsByIndex(int index) =>
      DateTime.utc(2000, 1, 1 + index).millisecondsSinceEpoch ~/ 1000;

  @override
  void initState() {
    super.initState();
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      final iframe = document.createElement('iframe') as HTMLIFrameElement;
      iframe.style.width = '100%';
      iframe.style.height = '100%';
      iframe.style.border = 'none';
      iframe.style.display = 'block';
      _iframe = iframe;
      iframe.srcdoc = _buildSrcDoc().toJS;
      return iframe;
    });
  }

  @override
  void didUpdateWidget(covariant StrategyEfficiencyLightweightChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _iframe?.srcdoc = _buildSrcDoc().toJS;
    });
  }

  String _buildSrcDoc() {
    final sorted = List<StrategyDailyEfficiencyRow>.from(widget.rows)
      ..sort((a, b) {
        final ta = _utcSecondsForChartTime(a.day);
        final tb = _utcSecondsForChartTime(b.day);
        if (ta != null && tb != null) return ta.compareTo(tb);
        if (ta != null) return -1;
        if (tb != null) return 1;
        return a.day.compareTo(b.day);
      });
    final payload = <Map<String, dynamic>>[];
    for (var i = 0; i < sorted.length; i++) {
      final e = sorted[i];
      payload.add({
        't': _stableUtcSecondsByIndex(i),
        'cashPct': e.cashDeltaPct,
        'trPct': e.trPct,
        'ratio': e.efficiencyRatio,
      });
    }
    final b64 = base64Encode(utf8.encode(jsonEncode(payload)));

    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html,body{margin:0;padding:0;height:100%;background:#141419;overflow:hidden;}
#c{width:100%;height:100%;}
#msg{position:absolute;left:12px;top:10px;right:12px;color:#b4b4c0;font:12px/1.4 system-ui,sans-serif;z-index:2;pointer-events:none;}
</style>
</head>
<body>
<div id="msg"></div>
<div id="c"></div>
<script src="https://cdn.jsdelivr.net/npm/lightweight-charts@4.2.0/dist/lightweight-charts.standalone.production.js"></script>
<script>
(function(){
  var B64 = '$b64';
  var DATA;
  try { DATA = JSON.parse(atob(B64)); } catch (e) { DATA = []; }
  var msgEl = document.getElementById('msg');
  function setMsg(t) { if (msgEl) msgEl.textContent = t || ''; }
  function n(v) {
    if (v == null || v !== v) return null;
    var x = Number(v);
    return (x === x && x !== Infinity && x !== -Infinity) ? x : null;
  }
  function boot() {
    var el = document.getElementById('c');
    if (!el) return;
    if (typeof LightweightCharts === 'undefined') {
      setMsg('图表库未能加载（请检查网络或对 cdn.jsdelivr.net 的访问）。');
      return;
    }
    if (!DATA || !DATA.length) {
      setMsg('暂无可绘制的数据。');
      return;
    }
    var chart = LightweightCharts.createChart(el, {
      layout: {
        background: { type: 'solid', color: '#141419' },
        textColor: '#F7F7F7',
      },
      grid: {
        vertLines: { color: 'rgba(42,42,53,0.55)' },
        horzLines: { color: 'rgba(42,42,53,0.55)' },
      },
      rightPriceScale: { borderColor: '#2a2a35', scaleMargins: { top: 0.05, bottom: 0.05 } },
      leftPriceScale: { visible: true, borderColor: '#2a2a35' },
      timeScale: {
        borderColor: '#2a2a35',
        timeVisible: true,
        secondsVisible: false,
        fixLeftEdge: true,
        fixRightEdge: true,
        barSpacing: 10,
        minBarSpacing: 4,
      },
      crosshair: { vertLine: { color: '#555' }, horzLine: { color: '#555' } },
    });
    var patternCache = {};
    function barPattern(kind, baseRgba) {
      var key = kind + '|' + baseRgba;
      if (patternCache[key]) return patternCache[key];
      var sz = kind === 'grid' ? 12 : 10;
      var p = document.createElement('canvas');
      p.width = sz;
      p.height = sz;
      var x = p.getContext('2d');
      if (!x) return baseRgba;
      x.fillStyle = baseRgba;
      x.fillRect(0, 0, sz, sz);
      if (kind === 'grid') {
        x.strokeStyle = 'rgba(255,255,255,0.4)';
        x.lineWidth = 1;
        for (var g = 0; g <= sz; g += 4) {
          x.beginPath();
          x.moveTo(0, g);
          x.lineTo(sz, g);
          x.stroke();
          x.beginPath();
          x.moveTo(g, 0);
          x.lineTo(g, sz);
          x.stroke();
        }
        x.strokeStyle = 'rgba(0,0,0,0.22)';
        x.lineWidth = 1;
        x.strokeRect(0.5, 0.5, sz - 1, sz - 1);
      } else {
        x.strokeStyle = 'rgba(0,0,0,0.24)';
        x.lineWidth = 1.2;
        x.beginPath();
        for (var o = -sz * 2; o <= sz * 2; o += 4) {
          x.moveTo(o, 0);
          x.lineTo(o + sz, sz);
        }
        x.stroke();
        x.strokeStyle = 'rgba(255,255,255,0.16)';
        x.beginPath();
        for (var o2 = -sz; o2 <= sz * 2; o2 += 4) {
          x.moveTo(o2, sz);
          x.lineTo(o2 + sz, 0);
        }
        x.stroke();
      }
      var probe = document.createElement('canvas').getContext('2d');
      var pat = probe && probe.createPattern(p, 'repeat');
      patternCache[key] = pat || baseRgba;
      return patternCache[key];
    }
    function trBarColor(tp) {
      if (tp == null || tp !== tp) return 'rgba(160, 160, 176, 0.45)';
      if (tp < 6) return 'rgba(245, 245, 245, 0.58)';
      if (tp <= 10) return 'rgba(234, 179, 8, 0.75)';
      return 'rgba(239, 68, 68, 0.82)';
    }
    function cashYieldBarColor(cp) {
      if (cp == null || cp !== cp) return 'rgba(160, 160, 176, 0.4)';
      if (cp < 0.5) return 'rgba(107, 114, 128, 0.58)';
      if (cp < 1) return 'rgba(245, 245, 245, 0.52)';
      return 'rgba(34, 197, 94, 0.62)';
    }
    var trH = chart.addHistogramSeries({
      priceScaleId: 'left_tr',
      priceFormat: { type: 'price', precision: 2, minMove: 0.01 },
      base: 0,
    });
    var cashH = chart.addHistogramSeries({
      priceScaleId: 'left_cash',
      priceFormat: { type: 'price', precision: 2, minMove: 0.01 },
      base: 0,
    });
    chart.priceScale('left_tr').applyOptions({
      scaleMargins: { top: 0.04, bottom: 0.52 },
    });
    chart.priceScale('left_cash').applyOptions({
      scaleMargins: { top: 0.52, bottom: 0.06 },
    });
    var cashArr = [];
    var trArr = [];
    for (var i = 0; i < DATA.length; i++) {
      var d = DATA[i];
      if (!d || d.t == null || d.t !== d.t) continue;
      var cp = n(d.cashPct);
      var tp = n(d.trPct);
      var cashBase = cashYieldBarColor(cp);
      var trBase = trBarColor(tp);
      cashArr.push({
        time: d.t,
        value: cp == null ? 0 : Math.round(cp * 100) / 100,
        color: barPattern('grid', cashBase),
      });
      trArr.push({
        time: d.t,
        value: tp == null ? 0 : Math.round(tp * 100) / 100,
        color: barPattern('diag', trBase),
      });
    }
    trH.setData(trArr);
    cashH.setData(cashArr);
    var linePts = [];
    for (var j = 0; j < DATA.length; j++) {
      var row = DATA[j];
      if (!row || row.t == null || row.t !== row.t) continue;
      var rv = n(row.ratio);
      if (rv != null) linePts.push({ time: row.t, value: rv });
    }
    if (linePts.length) {
      var serE = chart.addLineSeries({
        priceScaleId: 'right',
        color: 'rgba(107, 114, 128, 0.95)',
        lineWidth: 2,
        priceFormat: {
          type: 'custom',
          minMove: 0.1,
          formatter: function (p) {
            var x = Number(p);
            if (x !== x) return '';
            return x.toFixed(1) + '%';
          },
        },
      });
      serE.setData(linePts);
    } else {
      setMsg('柱图已加载；策略能效折线暂无有效点（多为当日无现金增量或波幅为 0）。');
    }
    chart.timeScale().fitContent();
    function resize() {
      var w = el.clientWidth;
      var h = el.clientHeight;
      if (w > 0 && h > 0) chart.applyOptions({ width: w, height: h });
    }
    try {
      var ro = new ResizeObserver(resize);
      ro.observe(el);
    } catch (e) {}
    var nFrames = 0;
    function rafSize() {
      resize();
      nFrames++;
      if (nFrames < 8 && (el.clientWidth < 2 || el.clientHeight < 2)) {
        requestAnimationFrame(rafSize);
      }
    }
    requestAnimationFrame(rafSize);
  }
  if (document.readyState === 'complete') boot();
  else window.addEventListener('load', boot);
})();
</script>
</body>
</html>
''';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: HtmlElementView(viewType: _viewType),
    );
  }
}
