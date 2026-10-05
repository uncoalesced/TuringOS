(() => {
  const PLAN_SOCKET = "ws://localhost:8080/plan";
  const OMNI_BAR_ID = "turingos-omni-bar";

  let currentPlan = null;
  let planSocket = null;
  let onPlanResolve = null;

  function createOmniBar() {
    const bar = document.createElement("div");
    bar.id = OMNI_BAR_ID;
    bar.className = "omni-bar";
    bar.innerHTML = `
      <div class="omni-bar-backdrop"></div>
      <div class="omni-bar-window">
        <div class="omni-bar-header">
          <span class="omni-bar-title">Plan Review</span>
          <button class="omni-bar-close" aria-label="Cancel">×</button>
        </div>
        <div class="omni-bar-intent"></div>
        <div class="omni-bar-steps"></div>
        <div class="omni-bar-actions">
          <button class="omni-bar-btn secondary" data-action="edit">Edit</button>
          <button class="omni-bar-btn danger" data-action="reject">Reject</button>
          <button class="omni-bar-btn primary" data-action="approve">Approve</button>
        </div>
      </div>
    `;
    document.body.appendChild(bar);
    return bar;
  }

  function getOmniBar() {
    return document.getElementById(OMNI_BAR_ID) || createOmniBar();
  }

  function riskClass(risk) {
    return risk === "high" ? "risk-high" : risk === "medium" ? "risk-medium" : "risk-low";
  }

  function riskLabel(risk) {
    const labels = { low: "Low", medium: "Medium", high: "High" };
    return labels[risk] || risk;
  }

  function stepKindIcon(kind) {
    const icons = { tool_call: "⚙", model_call: "🧠", ui: "🖼" };
    return icons[kind] || "•";
  }

  function renderPlan(bar, plan) {
    const intentEl = bar.querySelector(".omni-bar-intent");
    const stepsEl = bar.querySelector(".omni-bar-steps");

    intentEl.textContent = plan.intent;

    stepsEl.innerHTML = plan.steps.map((step, i) => `
      <div class="omni-bar-step" data-step-id="${step.step_id}">
        <span class="step-index">${i + 1}</span>
        <span class="step-kind">${stepKindIcon(step.kind)} ${step.kind.replace("_", " ")}</span>
        <span class="step-desc">${stepDescription(step)}</span>
        <span class="step-risk ${riskClass(step.risk)}">${riskLabel(step.risk)}</span>
      </div>
    `).join("");
  }

  function stepDescription(step) {
    if (step.kind === "tool_call") {
      const tool = step.tool || "unknown";
      const args = step.args ? JSON.stringify(step.args).slice(0, 60) : "";
      return `${tool} ${args}`;
    }
    if (step.kind === "model_call") {
      return step.prompt_template || "Model call";
    }
    if (step.kind === "ui") {
      return `${step.component || "UI"} component`;
    }
    return step.kind;
  }

  function showPlan(plan) {
    currentPlan = plan;
    const bar = getOmniBar();
    renderPlan(bar, plan);
    bar.classList.add("visible");
    document.body.classList.add("omni-bar-open");

    document.addEventListener("keydown", onKeyDown);
  }

  function hidePlan() {
    const bar = document.getElementById(OMNI_BAR_ID);
    if (bar) bar.classList.remove("visible");
    document.body.classList.remove("omni-bar-open");
    document.removeEventListener("keydown", onKeyDown);
    currentPlan = null;
  }

  function onKeyDown(e) {
    if (e.key === "Escape") {
      rejectPlan();
    }
  }

  function approvePlan() {
    if (!currentPlan) return;
    sendPlanAction("approve_plan", { plan_id: currentPlan.plan_id, session_id: currentPlan.session_id });
    resolvePlan(true);
  }

  function rejectPlan() {
    if (!currentPlan) return;
    sendPlanAction("approve_plan", { plan_id: currentPlan.plan_id, session_id: currentPlan.session_id, rejected: true });
    resolvePlan(false);
  }

  function editPlan() {
    if (!currentPlan) return;
    const newIntent = prompt("Edit intent:", currentPlan.intent);
    if (newIntent && newIntent !== currentPlan.intent) {
      sendPlanAction("create_plan", {
        session_id: currentPlan.session_id,
        intent: newIntent,
        steps: currentPlan.steps,
      });
    }
  }

  function sendPlanAction(action, payload) {
    if (planSocket && planSocket.readyState === WebSocket.OPEN) {
      planSocket.send(JSON.stringify({ action, ...payload }));
    }
  }

  function resolvePlan(approved) {
    if (onPlanResolve) {
      onPlanResolve(approved, currentPlan);
      onPlanResolve = null;
    }
    hidePlan();
  }

  function connectPlanSocket() {
    planSocket = new WebSocket(PLAN_SOCKET);
    planSocket.onopen = () => console.log("[plan-renderer] connected");
    planSocket.onclose = () => setTimeout(connectPlanSocket, 2000);
    planSocket.onerror = (e) => console.warn("[plan-renderer] socket error", e);
  }

  function init() {
    const bar = getOmniBar();
    bar.querySelector(".omni-bar-close").addEventListener("click", rejectPlan);
    bar.querySelector("[data-action=approve]").addEventListener("click", approvePlan);
    bar.querySelector("[data-action=reject]").addEventListener("click", rejectPlan);
    bar.querySelector("[data-action=edit]").addEventListener("click", editPlan);
    bar.querySelector(".omni-bar-backdrop").addEventListener("click", rejectPlan);

    connectPlanSocket();

    window.turingosPlan = {
      show: (plan, resolve) => {
        onPlanResolve = resolve;
        showPlan(plan);
      },
      hide: hidePlan,
    };
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();