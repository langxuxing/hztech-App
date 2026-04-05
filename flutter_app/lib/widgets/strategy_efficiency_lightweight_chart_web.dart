// Web-only：嵌入 Lightweight Charts（iframe），非 Flutter 插件场景下使用 package:web。
// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart';

import '../api/models.dart';

/// Web：使用 TradingView [Lightweight Charts](https://www.tradingview.com/lightweight-charts/) 展示策略能效。
/// 每日波动率% 柱：低于 6% 白、6%–10% 黄、高于 10% 红。
/// 现金收益率% 柱：&lt;0.5% 灰、0.5%–1% 白、≥1% 绿（无现金收益率折线）。
/// 策略能效折线（右轴）：&lt;0.25 灰、0.25–0.5 绿、≥0.5 深绿。
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
      ..sort((a, b) => a.day.compareTo(b.day));
    final payload = sorted
        .map(
          (e) => <String, dynamic>{
            'day': e.day,
            'cashPct': e.cashDeltaPct,
            'trPct': e.trPct,
            'ratio': e.efficiencyRatio,
          },
        )
        .toList();
    final b64 = base64Encode(utf8.encode(jsonEncode(payload)));

    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<script src="https://unpkg.com/lightweight-charts@4.2.0/dist/lightweight-charts.standalone.production.js"></script>
<style>
html,body{margin:0;padding:0;height:100%;background:#141419;overflow:hidden;}
</style>
</head>
<body>
<div id="c" style="width:100%;height:100%;"></div>
<script>
(function(){
  var B64 = '$b64';
  var DATA;
  try { DATA = JSON.parse(atob(B64)); } catch (e) { DATA = []; }
  function n(v) {
    if (v == null || v !== v) return null;
    var x = Number(v);
    return (x === x && x !== Infinity && x !== -Infinity) ? x : null;
  }
  var el = document.getElementById('c');
  if (!el || typeof LightweightCharts === 'undefined') return;
  var chart = LightweightCharts.createChart(el, {
    layout: {
      background: { type: 'solid', color: '#141419' },
      textColor: '#A0A0B0',
    },
    grid: {
      vertLines: { color: 'rgba(42,42,53,0.55)' },
      horzLines: { color: 'rgba(42,42,53,0.55)' },
    },
    rightPriceScale: { borderColor: '#2a2a35' },
    leftPriceScale: { visible: true, borderColor: '#2a2a35' },
    timeScale: { borderColor: '#2a2a35', timeVisible: true, secondsVisible: false },
    crosshair: { vertLine: { color: '#555' }, horzLine: { color: '#555' } },
  });
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
  function effLineColor(rv) {
    if (rv == null || rv !== rv) return null;
    if (rv < 0.25) return 'rgba(107, 114, 128, 0.98)';
    if (rv < 0.5) return 'rgba(74, 222, 128, 0.98)';
    return 'rgba(22, 101, 52, 0.98)';
  }
  var trH = chart.addHistogramSeries({
    priceScaleId: 'left',
    priceFormat: { type: 'price', precision: 0, minMove: 1 },
  });
  var cashH = chart.addHistogramSeries({
    priceScaleId: 'left',
    priceFormat: { type: 'price', precision: 1, minMove: 0.1 },
  });
  var cashArr = [];
  var trArr = [];
  for (var i = 0; i < DATA.length; i++) {
    var d = DATA[i];
    if (!d || !d.day) continue;
    var cp = n(d.cashPct);
    var tp = n(d.trPct);
    cashArr.push({
      time: d.day,
      value: cp == null ? 0 : Math.round(cp * 10) / 10,
      color: cashYieldBarColor(cp),
    });
    trArr.push({
      time: d.day,
      value: tp == null ? 0 : Math.round(tp),
      color: trBarColor(tp),
    });
  }
  trH.setData(trArr);
  cashH.setData(cashArr);
  var curE = null;
  var runE = [];
  for (var j = 0; j < DATA.length; j++) {
    var row = DATA[j];
    if (!row || !row.day) continue;
    var rv = n(row.ratio);
    var ec = effLineColor(rv);
    if (ec == null) {
      if (curE != null && runE.length) {
        var serE = chart.addLineSeries({
          priceScaleId: 'right',
          color: curE,
          lineWidth: 2,
          priceFormat: { type: 'price', precision: 8, minMove: 0.00000001 },
        });
        serE.setData(runE);
        runE = [];
        curE = null;
      }
      continue;
    }
    if (ec !== curE) {
      if (curE != null && runE.length) {
        var serE2 = chart.addLineSeries({
          priceScaleId: 'right',
          color: curE,
          lineWidth: 2,
          priceFormat: { type: 'price', precision: 8, minMove: 0.00000001 },
        });
        serE2.setData(runE);
      }
      runE = [];
      curE = ec;
    }
    runE.push({ time: row.day, value: rv });
  }
  if (curE != null && runE.length) {
    var serE3 = chart.addLineSeries({
      priceScaleId: 'right',
      color: curE,
      lineWidth: 2,
      priceFormat: { type: 'price', precision: 8, minMove: 0.00000001 },
    });
    serE3.setData(runE);
  }
  chart.timeScale().fitContent();
  function resize() {
    chart.applyOptions({ width: el.clientWidth, height: el.clientHeight });
  }
  try {
    var ro = new ResizeObserver(resize);
    ro.observe(el);
  } catch (e) {}
  resize();
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
