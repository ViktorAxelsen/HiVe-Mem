"use strict";

(() => {
  const data = JSON.parse(document.getElementById("benchmark-data").textContent);
  const datasetSelect = document.getElementById("dataset-select");
  const modelButtons = [...document.querySelectorAll("[data-model]")];
  const datasetNames = {average: "three-benchmark average", memgallery: "Mem-Gallery", wma: "WorldMemArena (Lifelong)", h2hmem: "H2HMem"};
  let model = "qwen";

  function renderResults() {
    const dataset = datasetSelect.value;
    const rows = data[model][dataset];
    const maxTokens = Math.max(...rows.map(row => row[2]));
    const bestF1 = Math.max(...rows.map(row => row[0]));
    const bestLJ = Math.max(...rows.map(row => row[1]));
    const bestTokens = Math.min(...rows.map(row => row[2]));
    const body = document.getElementById("results-body");
    body.replaceChildren();
    rows.forEach((values, index) => {
      const tr = document.createElement("tr");
      const ours = data.methods[index] === "HiVe-Mem";
      if (ours) tr.className = "ours";
      const heading = document.createElement("th");
      heading.scope = "row";
      heading.textContent = data.methods[index];
      if (ours) {
        const badge = document.createElement("span");
        badge.textContent = "Ours";
        heading.append(" ", badge);
      }
      tr.append(heading);
      values.forEach((value, metric) => {
        const cell = document.createElement("td");
        cell.textContent = value.toFixed(metric === 2 ? 3 : 2);
        if (value === [bestF1, bestLJ, bestTokens][metric]) cell.className = "best-score";
        tr.append(cell);
      });
      const barCell = document.createElement("td");
      const track = document.createElement("span");
      track.className = "token-track";
      track.setAttribute("aria-hidden", "true");
      const bar = document.createElement("span");
      bar.style.width = `${values[2] / maxTokens * 100}%`;
      track.append(bar);
      barCell.append(track);
      tr.append(barCell);
      body.append(tr);
    });
    const ours = rows[data.methods.indexOf("HiVe-Mem")];
    const competitorTokens = Math.min(...rows.filter((_, i) => data.methods[i] !== "HiVe-Mem").map(row => row[2]));
    const savings = (1 - ours[2] / competitorTokens) * 100;
    document.getElementById("result-lj").textContent = ours[1].toFixed(2);
    setMetric("result-tokens", ours[2].toFixed(3), "M");
    setMetric("result-savings", savings.toFixed(1), "%");
    document.getElementById("results-caption").textContent = `${data[model].name} · ${datasetNames[dataset]} · paper Table 1`;
    modelButtons.forEach(button => {
      const active = button.dataset.model === model;
      button.classList.toggle("is-active", active);
      button.setAttribute("aria-pressed", String(active));
    });
  }

  function setMetric(id, value, unit) {
    const el = document.getElementById(id);
    const unitEl = document.createElement("span");
    unitEl.textContent = unit;
    el.replaceChildren(value, unitEl);
  }

  modelButtons.forEach(button => {
    button.disabled = false;
    button.addEventListener("click", () => { model = button.dataset.model; renderResults(); });
  });
  datasetSelect.disabled = false;
  datasetSelect.addEventListener("change", renderResults);
  renderResults();

  const examples = {
    trip: {selected: ["summary"], explanation: "A compact summary can connect Mei’s bag to the Kyoto trip."},
    color: {selected: ["caption", "gvv"], explanation: "A caption and a focused view preserve the bag’s color without the full scene."}
  };
  const exampleButtons = [...document.querySelectorAll("[data-example]")];
  exampleButtons.forEach(button => {
    button.disabled = false;
    button.addEventListener("click", () => {
      const example = examples[button.dataset.example];
      exampleButtons.forEach(other => {
        const active = other === button;
        other.classList.toggle("is-active", active);
        other.setAttribute("aria-pressed", String(active));
      });
      document.querySelectorAll("[data-evidence]").forEach(row => {
        const selected = example.selected.includes(row.dataset.evidence);
        row.classList.toggle("is-selected", selected);
        const mark = row.querySelector(".evidence-check");
        mark.textContent = selected ? "✓" : "—";
        mark.setAttribute("aria-label", selected ? "Included" : "Excluded");
      });
      document.getElementById("example-explanation").textContent = example.explanation;
    });
  });

  const copyButton = document.getElementById("copy-citation");
  const status = document.getElementById("copy-status");
  let resetCopy;
  copyButton.disabled = false;
  copyButton.addEventListener("click", async () => {
    const citation = document.getElementById("citation-code");
    const text = citation.textContent;
    let copied = false;
    if (navigator.clipboard && window.isSecureContext) {
      try { await navigator.clipboard.writeText(text); copied = true; } catch (_) { /* Fall back to selection. */ }
    }
    if (!copied) {
      const selection = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(citation);
      selection.removeAllRanges();
      selection.addRange(range);
      try { copied = document.execCommand("copy"); } catch (_) { copied = false; }
      if (copied) selection.removeAllRanges();
    }
    const message = copied ? "Citation copied" : "Citation selected — press Ctrl/Cmd+C";
    copyButton.textContent = copied ? "Copied ✓" : "Press Ctrl/Cmd+C";
    status.textContent = message;
    clearTimeout(resetCopy);
    resetCopy = setTimeout(() => { copyButton.textContent = "Copy citation ⧉"; }, 2800);
  });
})();
