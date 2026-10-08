<script lang="ts">
  import { onMount } from 'svelte';
  import * as echarts from 'echarts/core';
  import { LineChart } from 'echarts/charts';
  import { GridComponent, MarkLineComponent, TooltipComponent } from 'echarts/components';
  import { historyResets } from './present.js';
  import { SVGRenderer } from 'echarts/renderers';

  echarts.use([LineChart, GridComponent, MarkLineComponent, TooltipComponent, SVGRenderer]);

  interface Props {
    series: Array<{ name: string; points: Array<[number, number]> }>;
    label: string;
    /** True when points are remaining percentages, so a reset is a rise. */
    remainingMode?: boolean;
  }
  let { series, label, remainingMode = false }: Props = $props();

  let element: HTMLDivElement | undefined = $state();
  let chart: echarts.ECharts | undefined;
  let theme = $state(0);

  const palette = (node: HTMLElement) => {
    const style = getComputedStyle(node);
    const read = (name: string, fallback: string) => style.getPropertyValue(name).trim() || fallback;
    return {
      text: read('--text-3', '#8a8d91'), line: read('--line', '#e3e1d9'), surface: read('--surface', '#fff'), ink: read('--text', '#17181a'),
      lines: [read('--accent', '#4b3ff2'), read('--trend-2', '#d6862f'), read('--trend-3', '#2f9e8f'), read('--trend-4', '#a04fd6')],
    };
  };
  const time = new Intl.DateTimeFormat(undefined, { weekday: 'short', hour: 'numeric', minute: '2-digit' });

  // A reset is a sharp drop in usage, or a sharp rise when the series shows remaining.
  const resets = $derived([...new Set(series.flatMap((item) => {
    const falling = historyResets(item.points);
    const rising = historyResets(item.points.map(([time, value]): [number, number] => [time, 100 - value]));
    return remainingMode ? rising : falling;
  }))].sort((a, b) => a - b));

  function render() {
    if (!element) return;
    chart ??= echarts.init(element, undefined, { renderer: 'svg' });
    const colors = palette(element);
    chart.setOption({
      animation: false,
      color: colors.lines,
      grid: { left: 30, right: 6, top: 8, bottom: 20 },
      tooltip: {
        trigger: 'axis', backgroundColor: colors.surface, borderColor: colors.line, textStyle: { color: colors.ink, fontSize: 12 },
        valueFormatter: (value: unknown) => typeof value === 'number' ? `${value}%` : String(value),
        axisPointer: { lineStyle: { color: colors.line } },
      },
      xAxis: {
        type: 'time', axisLine: { lineStyle: { color: colors.line } }, axisTick: { show: false },
        axisLabel: { color: colors.text, fontSize: 10, hideOverlap: true, formatter: { day: '{ee}', hour: '{HH}:{mm}' } },
        splitLine: { show: false },
      },
      yAxis: {
        type: 'value', min: 0, max: 100, interval: 50,
        axisLabel: { color: colors.text, fontSize: 10, formatter: '{value}%' },
        splitLine: { lineStyle: { color: colors.line, type: 'dashed' } },
      },
      series: series.map((item, index) => ({
        name: item.name, type: 'line', data: item.points, showSymbol: item.points.length < 3, symbolSize: 4,
        lineStyle: { width: 1.6 }, areaStyle: series.length === 1 ? { opacity: 0.08 } : undefined, step: false,
        // Resets show as dashed vertical lines where a window's usage dropped.
        ...(index === 0 && resets.length ? { markLine: {
          silent: true, symbol: 'none', animation: false,
          lineStyle: { color: colors.text, type: 'dashed', width: 1 },
          label: { show: true, position: 'insideEndTop', formatter: 'Reset', color: colors.text, fontSize: 9 },
          data: resets.map((time) => ({ xAxis: time })),
        } } : {}),
      })),
    }, true);
    chart.resize();
  }

  onMount(() => {
    const media = window.matchMedia('(prefers-color-scheme: dark)');
    const onTheme = () => { theme++; };
    media.addEventListener('change', onTheme);
    // Hosts can override the system theme with html[data-theme].
    const themeObserver = new MutationObserver(onTheme);
    themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    const observer = new ResizeObserver(() => chart?.resize());
    if (element) observer.observe(element);
    return () => { media.removeEventListener('change', onTheme); themeObserver.disconnect(); observer.disconnect(); chart?.dispose(); chart = undefined; };
  });

  $effect(() => {
    void theme;
    void series;
    render();
  });

  const summary = $derived(series.map((item) => {
    const last = item.points.at(-1);
    return last ? `${item.name} ${last[1]}% at ${time.format(last[0])}` : item.name;
  }).join('; '));
</script>

<figure class="trend">
  <div bind:this={element} class="canvas" role="img" aria-label={`${label}. Latest: ${summary}.`}></div>
  {#if series.length > 1}
    <figcaption>
      {#each series as item, index (item.name)}<span><i class={`line-${index}`}></i>{item.name}</span>{/each}
    </figcaption>
  {/if}
</figure>

<style>
  .trend { margin: 0; }
  .canvas { width: 100%; height: 104px; }
  figcaption { display: flex; flex-wrap: wrap; gap: 4px 12px; font-size: .74rem; color: var(--text-3); margin-top: 4px; }
  figcaption span { display: inline-flex; align-items: center; gap: 5px; }
  figcaption i { width: 10px; height: 2px; border-radius: 1px; background: var(--accent); }
  figcaption i.line-1 { background: var(--trend-2); }
  figcaption i.line-2 { background: var(--trend-3); }
  figcaption i.line-3 { background: var(--trend-4); }
</style>
