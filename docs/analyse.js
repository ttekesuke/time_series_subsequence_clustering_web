(() => {
  'use strict';

  const MIN_WINDOW = 2;
  const CLUSTER_COLORS = ['#1c8c70', '#e97856', '#527ed4', '#ae7a20', '#765cc4', '#258ba1', '#bd5570', '#4d8662'];

  const elements = {
    seriesInput: document.querySelector('#seriesInput'),
    thresholdInput: document.querySelector('#thresholdInput'),
    minWidthInput: document.querySelector('#minWidthInput'),
    rebuildButton: document.querySelector('#rebuildButton'),
    inputError: document.querySelector('#inputError'),
    prevButton: document.querySelector('#prevButton'),
    nextButton: document.querySelector('#nextButton'),
    playButton: document.querySelector('#playButton'),
    stepSlider: document.querySelector('#stepSlider'),
    sliderTicks: document.querySelector('#sliderTicks'),
    stepKicker: document.querySelector('#stepKicker'),
    stepTitle: document.querySelector('#stepTitle'),
    stepCounter: document.querySelector('#stepCounter'),
    timelineChart: document.querySelector('#timelineChart'),
    activeSlice: document.querySelector('#activeSlice'),
    scaleGraphic: document.querySelector('#scaleGraphic'),
    decisionList: document.querySelector('#decisionList'),
    taskQueue: document.querySelector('#taskQueue'),
    clusterTree: document.querySelector('#clusterTree'),
    eventLog: document.querySelector('#eventLog'),
    snapshotSummary: document.querySelector('#snapshotSummary')
  };

  let simulation = null;
  let step = 0;
  let playTimer = null;

  class ClusterNode {
    constructor(id, starts, representative) {
      this.id = id;
      this.starts = [...starts];
      this.representative = [...representative];
      this.children = new Map();
    }
  }

  class Simulator {
    constructor(data, threshold, contextualMinWidth) {
      this.data = data;
      this.threshold = threshold;
      this.contextualMinWidth = contextualMinWidth;
      this.valueWidth = 1;
      this.roots = new Map();
      this.tasks = [];
      this.clusterIdCounter = 1;
      this.snapshots = [];
      this.currentEvents = [];
      this.currentComparisons = [];
      this.updatedIds = new Set([0]);
      this.scale = this.calculateScale(1);

      this.roots.set(0, new ClusterNode(0, [0], this.slice(0, MIN_WINDOW)));
      this.captureSnapshot(1, 'INITIAL SEED', '最初の長さ2を root cluster 0 に登録', [
        { kind: 'seed', text: `index 0 から長さ ${MIN_WINDOW} の ${formatSequence(this.slice(0, MIN_WINDOW))} を代表系列として初期化。` }
      ]);
    }

    run() {
      for (let dataIndex = MIN_WINDOW; dataIndex < this.data.length; dataIndex += 1) {
        this.processIndex(dataIndex);
      }
      return this.snapshots;
    }

    processIndex(dataIndex) {
      this.currentEvents = [];
      this.currentComparisons = [];
      this.updatedIds = new Set();
      this.scale = this.calculateScale(dataIndex);
      this.valueWidth = this.scale.width;
      this.currentEvents.push({
        kind: 'scale',
        text: `index ${dataIndex} の値 ${fmt(this.data[dataIndex])} を読み、value_width を ${fmt(this.valueWidth)} に更新。`
      });

      const currentTasks = this.tasks.map(task => ({ path: [...task.path], length: task.length }));
      this.tasks = [];
      if (currentTasks.length === 0) {
        this.currentEvents.push({ kind: 'task', text: '前回からの tasks は空。window の伸長処理はありません。' });
      }
      currentTasks.forEach(task => this.processTask(task, dataIndex));
      this.processRoot(dataIndex);

      const title = `index ${dataIndex}「${fmt(this.data[dataIndex])}」を読み込む`;
      this.captureSnapshot(dataIndex, `DATA INDEX ${dataIndex}`, title, this.currentEvents);
    }

    calculateScale(uptoIndex) {
      const context = this.data.slice(0, uptoIndex + 1);
      const mean = average(context);
      const lowerValues = context.filter(value => value <= mean);
      const upperValues = context.filter(value => value >= mean);
      const lower = lowerValues.length ? average(lowerValues) : 0;
      const upper = upperValues.length ? average(upperValues) : 0;
      const rawDelta = Math.abs(upper - lower);
      const width = Math.max(rawDelta, this.contextualMinWidth) || 1;
      return { mean, lower, upper, rawDelta, width, context: [...context] };
    }

    processTask(task, dataIndex) {
      const parent = this.dig(task.path);
      if (!parent) {
        this.currentEvents.push({ kind: 'skip', text: `task path [${task.path.join(', ')}] が見つからずスキップ。` });
        return;
      }
      const newLength = task.length + 1;
      const latestStart = dataIndex - newLength + 1;
      if (latestStart < 0) return;
      const latestSequence = this.slice(latestStart, newLength);
      const validStarts = parent.starts.filter(start => start + newLength <= dataIndex + 1 && start !== latestStart);
      this.currentEvents.push({
        kind: 'task',
        text: `task [${task.path.join(' → ')}] を実行。window ${task.length} → ${newLength}、最新開始 index は ${latestStart}。`
      });
      if (validStarts.length === 0) {
        this.currentEvents.push({ kind: 'skip', text: '比較可能な過去の開始 index がないため、この伸長は終了。' });
        return;
      }
      if (parent.children.size > 0) {
        this.processExistingChildren(parent, latestSequence, latestStart, newLength, task.path);
      } else {
        this.processNewChildren(parent, validStarts, latestSequence, latestStart, newLength, task.path);
      }
    }

    processExistingChildren(parent, latestSequence, latestStart, length, parentPath) {
      let best = null;
      [...parent.children.values()].sort((a, b) => a.id - b.id).forEach(child => {
        const comparison = this.compare(child.representative, latestSequence, length, {
          scope: 'child', clusterId: child.id, candidateStart: latestStart
        });
        this.currentComparisons.push(comparison);
        if (!best || comparison.distance < best.comparison.distance ||
            (comparison.distance === best.comparison.distance && child.id < best.child.id)) {
          best = { child, comparison };
        }
      });

      if (best && best.comparison.accepted) {
        best.child.starts.push(latestStart);
        best.child.representative = this.averageSequences(best.child.starts, length);
        this.updatedIds.add(best.child.id);
        this.tasks.push({ path: [...parentPath, best.child.id], length });
        this.currentEvents.push({
          kind: 'merge',
          text: `最も近い child cluster ${best.child.id} へ統合。代表系列を ${formatSequence(best.child.representative)} に更新し、次回 window ${length + 1} を予約。`
        });
      } else {
        const node = this.createNode([latestStart], latestSequence);
        parent.children.set(node.id, node);
        this.updatedIds.add(node.id);
        this.currentEvents.push({ kind: 'new', text: `既存 child の閾値を超えたため、cluster ${node.id} を新規作成。` });
      }
    }

    processNewChildren(parent, validStarts, latestSequence, latestStart, length, parentPath) {
      const validGroup = [];
      const invalidGroup = [];
      validStarts.forEach(start => {
        const sequence = this.slice(start, length);
        const comparison = this.compare(sequence, latestSequence, length, {
          scope: 'new-child', clusterId: null, candidateStart: latestStart, referenceStart: start
        });
        this.currentComparisons.push(comparison);
        (comparison.accepted ? validGroup : invalidGroup).push(start);
      });

      if (validGroup.length > 0) {
        const starts = [...validGroup, latestStart];
        const node = this.createNode(starts, this.averageSequences(starts, length));
        parent.children.set(node.id, node);
        this.updatedIds.add(node.id);
        this.tasks.push({ path: [...parentPath, node.id], length });
        this.currentEvents.push({
          kind: 'merge',
          text: `近い過去 [${validGroup.join(', ')}] と最新 ${latestStart} から child cluster ${node.id} を作成。次回 window ${length + 1} を予約。`
        });
      } else {
        const node = this.createNode([latestStart], latestSequence);
        parent.children.set(node.id, node);
        this.updatedIds.add(node.id);
        this.currentEvents.push({ kind: 'new', text: `近い過去がないため、最新だけの child cluster ${node.id} を作成。` });
      }

      invalidGroup.forEach(start => {
        const node = this.createNode([start], this.slice(start, length));
        parent.children.set(node.id, node);
        this.updatedIds.add(node.id);
        this.currentEvents.push({ kind: 'new', text: `閾値を超えた過去 index ${start} を単独 child cluster ${node.id} として保存。` });
      });
    }

    processRoot(dataIndex) {
      const latestStart = dataIndex - MIN_WINDOW + 1;
      const latestSequence = this.slice(latestStart, MIN_WINDOW);
      let best = null;

      [...this.roots.values()].sort((a, b) => a.id - b.id).forEach(root => {
        if (root.starts.includes(latestStart)) return;
        const comparison = this.compare(root.representative, latestSequence, MIN_WINDOW, {
          scope: 'root', clusterId: root.id, candidateStart: latestStart
        });
        this.currentComparisons.push(comparison);
        if (!best || comparison.distance < best.comparison.distance ||
            (comparison.distance === best.comparison.distance && root.id < best.root.id)) {
          best = { root, comparison };
        }
      });

      if (best && best.comparison.accepted) {
        best.root.starts.push(latestStart);
        best.root.representative = this.averageSequences(best.root.starts, MIN_WINDOW);
        this.updatedIds.add(best.root.id);
        this.tasks.push({ path: [best.root.id], length: MIN_WINDOW });
        this.currentEvents.push({
          kind: 'merge',
          text: `最新 ${formatSequence(latestSequence)} を root cluster ${best.root.id} へ統合。平均代表は ${formatSequence(best.root.representative)}。`
        });
      } else {
        const node = this.createNode([latestStart], latestSequence);
        this.roots.set(node.id, node);
        this.updatedIds.add(node.id);
        const reason = best ? `最小 ratio ${fmt(best.comparison.ratio)} が閾値 ${fmt(this.threshold)} を超えた` : '比較対象がない';
        this.currentEvents.push({ kind: 'new', text: `${reason}ため、root cluster ${node.id} を新規作成。` });
      }
    }

    compare(reference, candidate, length, meta) {
      const stepDistances = reference.slice(0, Math.min(reference.length, candidate.length)).map((value, index) =>
        Math.min(Math.abs(value - candidate[index]) / this.valueWidth, 1)
      );
      const squared = stepDistances.reduce((sum, distance) => sum + distance * distance, 0);
      const distance = Math.sqrt(squared);
      const maxDistance = Math.sqrt(Math.max(length, 1));
      const ratio = maxDistance === 0 ? 0 : distance / maxDistance;
      return {
        ...meta,
        reference: [...reference], candidate: [...candidate], stepDistances,
        distance, maxDistance, ratio, accepted: ratio <= this.threshold, length
      };
    }

    averageSequences(starts, length) {
      return Array.from({ length }, (_, offset) => average(starts.map(start => this.data[start + offset])));
    }

    createNode(starts, representative) {
      const node = new ClusterNode(this.clusterIdCounter, starts, representative);
      this.clusterIdCounter += 1;
      return node;
    }

    slice(start, length) {
      return this.data.slice(start, start + length);
    }

    dig(path) {
      if (!path.length) return null;
      let node = this.roots.get(path[0]);
      for (let i = 1; node && i < path.length; i += 1) node = node.children.get(path[i]);
      return node || null;
    }

    captureSnapshot(currentIndex, kicker, title, events) {
      const roots = [...this.roots.values()].sort((a, b) => a.id - b.id).map(node => serializeNode(node, MIN_WINDOW));
      this.snapshots.push({
        currentIndex, kicker, title,
        scale: { ...this.scale, context: [...this.scale.context] },
        valueWidth: this.valueWidth,
        roots,
        tasks: this.tasks.map(task => ({ path: [...task.path], length: task.length })),
        events: events.map(event => ({ ...event })),
        comparisons: this.currentComparisons.map(comparison => ({ ...comparison })),
        updatedIds: [...this.updatedIds],
        clusterCount: countNodes(roots),
        maxWindow: maxWindow(roots),
        mergedCount: events.filter(event => event.kind === 'merge').length,
        newCount: events.filter(event => event.kind === 'new').length
      });
    }
  }

  function serializeNode(node, window) {
    return {
      id: node.id,
      starts: [...node.starts].sort((a, b) => a - b),
      representative: [...node.representative],
      window,
      children: [...node.children.values()].sort((a, b) => a.id - b.id).map(child => serializeNode(child, window + 1))
    };
  }

  function countNodes(nodes) {
    return nodes.reduce((sum, node) => sum + 1 + countNodes(node.children), 0);
  }

  function maxWindow(nodes) {
    return nodes.reduce((maximum, node) => Math.max(maximum, node.window, maxWindow(node.children)), 0);
  }

  function average(values) {
    return values.reduce((sum, value) => sum + value, 0) / values.length;
  }

  function fmt(value, digits = 3) {
    if (!Number.isFinite(value)) return '—';
    const rounded = Number(value.toFixed(digits));
    return Number.isInteger(rounded) ? String(rounded) : String(rounded);
  }

  function formatSequence(sequence) {
    return `[${sequence.map(value => fmt(value, 2)).join(', ')}]`;
  }

  function colorFor(id) {
    return CLUSTER_COLORS[Math.abs(id) % CLUSTER_COLORS.length];
  }

  function parseInputs() {
    const tokens = elements.seriesInput.value.trim().split(/[\s,、]+/).filter(Boolean);
    const data = tokens.map(Number);
    const threshold = Number(elements.thresholdInput.value);
    const minWidth = Number(elements.minWidthInput.value);
    if (data.length < 3) throw new Error('時系列には3個以上の数値が必要です。');
    if (data.some(value => !Number.isFinite(value))) throw new Error('時系列に数値ではない値が含まれています。');
    if (data.some(value => !Number.isInteger(value))) throw new Error('analyse APIと同じく、時系列は整数で指定してください。');
    if (!Number.isFinite(threshold) || threshold < 0 || threshold > 1) throw new Error('統合閾値は0〜1で指定してください。');
    if (!Number.isFinite(minWidth) || minWidth <= 0) throw new Error('文脈の最小幅は0より大きい値にしてください。');
    return { data, threshold, minWidth };
  }

  function rebuild() {
    stopPlayback();
    try {
      const { data, threshold, minWidth } = parseInputs();
      simulation = {
        data,
        threshold,
        minWidth,
        snapshots: new Simulator(data, threshold, minWidth).run()
      };
      step = 0;
      elements.inputError.hidden = true;
      elements.stepSlider.max = String(simulation.snapshots.length - 1);
      elements.stepSlider.value = '0';
      renderTicks();
      render();
    } catch (error) {
      elements.inputError.textContent = error.message;
      elements.inputError.hidden = false;
    }
  }

  function render() {
    if (!simulation) return;
    const snapshot = simulation.snapshots[step];
    elements.stepSlider.value = String(step);
    elements.stepKicker.textContent = snapshot.kicker;
    elements.stepTitle.textContent = snapshot.title;
    elements.stepCounter.textContent = `${step + 1} / ${simulation.snapshots.length}`;
    elements.prevButton.disabled = step === 0;
    elements.nextButton.disabled = step === simulation.snapshots.length - 1;
    renderTimeline(snapshot);
    renderScale(snapshot);
    renderDecisions(snapshot);
    renderTasks(snapshot);
    renderTree(snapshot);
    renderEvents(snapshot);
    renderSummary(snapshot);
  }

  function renderTicks() {
    const count = simulation.snapshots.length;
    elements.sliderTicks.innerHTML = simulation.snapshots.map((snapshot, index) =>
      `<span>${index === 0 ? 'seed' : snapshot.currentIndex}</span>`
    ).join('');
    if (count > 14) elements.sliderTicks.querySelectorAll('span').forEach((tick, index) => {
      if (index % 2 === 1 && index !== count - 1) tick.style.visibility = 'hidden';
    });
  }

  function renderTimeline(snapshot) {
    const data = simulation.data;
    const width = Math.max(620, data.length * 55);
    const height = 190;
    const pad = { x: 35, y: 28 };
    const min = Math.min(...data);
    const max = Math.max(...data);
    const range = max - min || 1;
    const x = index => pad.x + index * ((width - pad.x * 2) / Math.max(data.length - 1, 1));
    const y = value => height - pad.y - ((value - min) / range) * (height - pad.y * 2);
    const processedPoints = data.slice(0, snapshot.currentIndex + 1).map((value, index) => `${x(index)},${y(value)}`).join(' ');
    const futurePoints = data.slice(snapshot.currentIndex).map((value, offset) => `${x(snapshot.currentIndex + offset)},${y(value)}`).join(' ');
    const latestStart = Math.max(0, snapshot.currentIndex - MIN_WINDOW + 1);
    const regionX = x(latestStart) - 13;
    const regionWidth = x(snapshot.currentIndex) - x(latestStart) + 26;
    const horizontalGrid = [0, .5, 1].map(t => {
      const gy = pad.y + t * (height - pad.y * 2);
      const label = max - t * range;
      return `<line class="chart-grid" x1="${pad.x}" y1="${gy}" x2="${width-pad.x}" y2="${gy}"/><text class="chart-label" x="2" y="${gy+3}">${fmt(label,1)}</text>`;
    }).join('');
    const points = data.map((value, index) => {
      const classes = ['chart-point'];
      if (index > snapshot.currentIndex) classes.push('future');
      if (index === snapshot.currentIndex) classes.push('current');
      return `<circle class="${classes.join(' ')}" cx="${x(index)}" cy="${y(value)}" r="${index === snapshot.currentIndex ? 5 : 3.5}"/><text class="chart-value" x="${x(index)}" y="${y(value)-10}" text-anchor="middle">${fmt(value,1)}</text><text class="chart-label" x="${x(index)}" y="${height-5}" text-anchor="middle">${index}</text>`;
    }).join('');
    elements.timelineChart.innerHTML = `<svg viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" aria-hidden="true">${horizontalGrid}<rect class="slice-region" x="${regionX}" y="${pad.y-8}" width="${regionWidth}" height="${height-pad.y*2+16}" rx="7"/><polyline class="chart-line future" points="${futurePoints}"/><polyline class="chart-line" points="${processedPoints}"/><line class="current-guide" x1="${x(snapshot.currentIndex)}" y1="18" x2="${x(snapshot.currentIndex)}" y2="${height-pad.y}"/>${points}</svg>`;
    elements.timelineChart.style.overflowX = width > 800 ? 'auto' : 'visible';
    const latestSequence = data.slice(latestStart, snapshot.currentIndex + 1);
    elements.activeSlice.innerHTML = `<span class="slice-label">最新 root 候補 / start ${latestStart}</span><span class="sequence-chip">${latestSequence.map((value, index) => `<i class="${index === latestSequence.length-1 ? 'active' : ''}">${fmt(value,1)}</i>`).join('')}</span><span class="slice-label">window ${latestSequence.length}</span>`;
  }

  function renderScale(snapshot) {
    const { mean, lower, upper, rawDelta, width, context } = snapshot.scale;
    const min = Math.min(...context);
    const max = Math.max(...context);
    const range = max - min || 1;
    const pos = value => Math.max(2, Math.min(98, ((value - min) / range) * 100));
    elements.scaleGraphic.innerHTML = `
      <div class="scale-number-row">
        <div class="scale-stat"><small>全体平均</small><strong>${fmt(mean)}</strong></div>
        <div class="scale-stat"><small>lower 平均</small><strong>${fmt(lower)}</strong></div>
        <div class="scale-stat"><small>upper 平均</small><strong>${fmt(upper)}</strong></div>
        <div class="scale-stat accent"><small>value_width</small><strong>${fmt(width)}</strong></div>
      </div>
      <div class="scale-bar">
        ${context.map(value => `<i class="scale-marker" style="left:${pos(value)}%" data-value="${fmt(value,1)}"></i>`).join('')}
        <div class="mean-line" style="left:${pos(mean)}%"><span>mean ${fmt(mean)}</span></div>
      </div>
      <p class="scale-explain">| ${fmt(upper)} − ${fmt(lower)} | = ${fmt(rawDelta)}。最小幅 ${fmt(simulation.minWidth)} と比べ、<strong>${fmt(width)}</strong> を距離の割り算に使用。</p>`;
  }

  function renderDecisions(snapshot) {
    if (snapshot.comparisons.length === 0) {
      elements.decisionList.innerHTML = '<div class="decision-empty">初期化では距離比較を行いません。<br>「次へ」で最初の候補を分類します。</div>';
      return;
    }
    elements.decisionList.innerHTML = snapshot.comparisons.map(comparison => {
      const scope = comparison.scope === 'root' ? `root cluster ${comparison.clusterId}` :
        comparison.scope === 'child' ? `child cluster ${comparison.clusterId}` : `過去 start ${comparison.referenceStart}`;
      const barWidth = Math.min(100, (comparison.ratio / Math.max(simulation.threshold, .001)) * 70);
      return `<article class="decision-card ${comparison.accepted ? 'accept' : 'reject'}">
        <div class="decision-top"><strong>${scope} と比較</strong><span class="decision-badge">${comparison.accepted ? '統合圏内' : '閾値超過'}</span></div>
        <div class="decision-seqs">${formatSequence(comparison.reference)} ↔ ${formatSequence(comparison.candidate)} · d=[${comparison.stepDistances.map(d => fmt(d)).join(', ')}]</div>
        <div class="ratio-row"><span>${fmt(comparison.distance)} ÷ ${fmt(comparison.maxDistance)}</span><div class="ratio-track"><div class="ratio-fill" style="width:${barWidth}%"></div></div><b>${fmt(comparison.ratio)} ${comparison.accepted ? '≤' : '>'} ${fmt(simulation.threshold)}</b></div>
      </article>`;
    }).join('');
  }

  function renderTasks(snapshot) {
    if (snapshot.tasks.length === 0) {
      elements.taskQueue.innerHTML = '<div class="queue-empty">予約なし<br><small>新規クラスタは、次の値ではまだ伸長されません</small></div>';
      return;
    }
    elements.taskQueue.innerHTML = snapshot.tasks.map(task => `<article class="task-card"><span class="task-icon">↗</span><div><small>CLUSTER PATH</small><strong>[${task.path.join(' → ')}]</strong></div><b>${task.length} → ${task.length + 1}</b></article>`).join('');
  }

  function renderTree(snapshot) {
    if (!snapshot.roots.length) {
      elements.clusterTree.innerHTML = '<p class="tree-empty">クラスタはまだありません。</p>';
      return;
    }
    elements.clusterTree.innerHTML = `<div class="tree-roots">${snapshot.roots.map(node => renderBranch(node, snapshot.updatedIds)).join('')}</div>`;
  }

  function renderBranch(node, updatedIds) {
    const updated = updatedIds.includes(node.id);
    const childMarkup = node.children.length ? `<div class="tree-children">${node.children.map(child => renderBranch(child, updatedIds)).join('')}</div>` : '';
    return `<div class="tree-branch"><article class="cluster-node ${updated ? 'updated' : ''}" style="--cluster-color:${colorFor(node.id)}">
      <div class="node-heading"><strong>cluster ${node.id}</strong><span>window ${node.window}</span></div>
      <div class="node-row"><b>si</b><div class="node-indices">${node.starts.map(start => `<i>${start}</i>`).join('')}</div></div>
      <div class="node-row"><b>as</b><div class="node-sequence">${formatSequence(node.representative)}</div></div>
    </article>${childMarkup}</div>`;
  }

  function renderEvents(snapshot) {
    elements.eventLog.innerHTML = snapshot.events.map(event => {
      const label = ({ scale: 'SCALE', task: 'TASK', skip: 'SKIP', merge: 'MERGE', new: 'NEW', seed: 'SEED' })[event.kind] || 'INFO';
      return `<li class="${event.kind === 'merge' || event.kind === 'new' || event.kind === 'seed' ? 'highlight' : ''}"><code>${label}</code>${event.text}</li>`;
    }).join('');
  }

  function renderSummary(snapshot) {
    const processed = snapshot.currentIndex + 1;
    const progress = Math.round((processed / simulation.data.length) * 100);
    const action = snapshot.mergedCount > 0 ? `${snapshot.mergedCount}件を統合` : snapshot.newCount > 0 ? `${snapshot.newCount}件を新規作成` : '初期クラスタを準備';
    elements.snapshotSummary.innerHTML = `
      <div class="summary-hero"><div class="summary-ring">${progress}%</div><div><small>STEP RESULT</small><strong>${action}</strong></div></div>
      <div class="summary-grid">
        <div class="summary-stat"><small>読込済み</small><strong>${processed} / ${simulation.data.length}</strong></div>
        <div class="summary-stat"><small>全 node</small><strong>${snapshot.clusterCount}</strong></div>
        <div class="summary-stat"><small>最大 window</small><strong>${snapshot.maxWindow}</strong></div>
      </div>
      <p class="summary-note">この表示の <code>si</code> はAPIレスポンスと同じ0-originです。次のデータ点では、tasksを処理してからrootを分類します。</p>`;
  }

  function moveTo(nextStep) {
    step = Math.max(0, Math.min(simulation.snapshots.length - 1, nextStep));
    render();
  }

  function togglePlayback() {
    if (playTimer) {
      stopPlayback();
      return;
    }
    if (step >= simulation.snapshots.length - 1) moveTo(0);
    elements.playButton.innerHTML = '<span>Ⅱ</span> 停止';
    elements.playButton.setAttribute('aria-label', '自動再生を停止');
    playTimer = window.setInterval(() => {
      if (step >= simulation.snapshots.length - 1) {
        stopPlayback();
      } else {
        moveTo(step + 1);
      }
    }, 1450);
  }

  function stopPlayback() {
    if (playTimer) window.clearInterval(playTimer);
    playTimer = null;
    elements.playButton.innerHTML = '<span>▶</span> 再生';
    elements.playButton.setAttribute('aria-label', '自動再生');
  }

  elements.rebuildButton.addEventListener('click', rebuild);
  elements.prevButton.addEventListener('click', () => { stopPlayback(); moveTo(step - 1); });
  elements.nextButton.addEventListener('click', () => { stopPlayback(); moveTo(step + 1); });
  elements.playButton.addEventListener('click', togglePlayback);
  elements.stepSlider.addEventListener('input', event => { stopPlayback(); moveTo(Number(event.target.value)); });
  document.querySelectorAll('[data-series]').forEach(button => button.addEventListener('click', () => {
    elements.seriesInput.value = button.dataset.series;
    rebuild();
  }));
  document.addEventListener('keydown', event => {
    if (event.target.matches('input, textarea')) return;
    if (event.key === 'ArrowLeft') { stopPlayback(); moveTo(step - 1); }
    if (event.key === 'ArrowRight') { stopPlayback(); moveTo(step + 1); }
    if (event.key === ' ') { event.preventDefault(); togglePlayback(); }
  });

  rebuild();
})();
