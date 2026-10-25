(() => {
  const root = document.documentElement;
  root.classList.remove("no-js");
  root.classList.add("js");

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const header = document.querySelector(".site-header");

  const onScroll = () => {
    if (!header) return;
    header.classList.toggle("is-scrolled", window.scrollY > 10);
  };
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  // Reveal sections once, without keeping observers around.
  const reveals = Array.from(document.querySelectorAll(".reveal"));
  const staticView = new URLSearchParams(window.location.search).has("static");
  if (staticView) {
    reveals.forEach((element) => element.classList.add("is-visible"));
  } else if (reduceMotion || !("IntersectionObserver" in window)) {
    reveals.forEach((element) => element.classList.add("is-visible"));
  } else {
    const revealObserver = new IntersectionObserver((entries, observer) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.06 });
    reveals.forEach((element) => revealObserver.observe(element));
  }

  // The interface tabs: click or arrow keys, with one panel visible at a time.
  const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
  const panels = Array.from(document.querySelectorAll('[role="tabpanel"]'));

  const activateTab = (tab, focusTab = true) => {
    const panelId = tab.getAttribute("aria-controls");
    tabs.forEach((other) => {
      const selected = other === tab;
      other.setAttribute("aria-selected", String(selected));
      other.tabIndex = selected ? 0 : -1;
    });
    panels.forEach((panel) => {
      panel.hidden = panel.id !== panelId;
    });
    if (focusTab) tab.focus();
  };

  tabs.forEach((tab, index) => {
    tab.addEventListener("click", () => activateTab(tab, false));
    tab.addEventListener("keydown", (event) => {
      let next = null;
      if (event.key === "ArrowDown" || event.key === "ArrowRight") next = tabs[(index + 1) % tabs.length];
      if (event.key === "ArrowUp" || event.key === "ArrowLeft") next = tabs[(index - 1 + tabs.length) % tabs.length];
      if (event.key === "Home") next = tabs[0];
      if (event.key === "End") next = tabs[tabs.length - 1];
      if (!next) return;
      event.preventDefault();
      activateTab(next);
    });
  });

  // The mobile menu closes when a link is chosen, when the page is clicked, or on Escape.
  const menu = document.querySelector(".mobile-menu");
  if (menu) {
    menu.querySelectorAll("a").forEach((link) => {
      link.addEventListener("click", () => { menu.open = false; });
    });
    document.addEventListener("click", (event) => {
      if (menu.open && !menu.contains(event.target)) menu.open = false;
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && menu.open) {
        menu.open = false;
        const summary = menu.querySelector("summary");
        if (summary) summary.focus();
      }
    });
  }

  // Section links carry a quiet current marker while the matching section is in view.
  const sectionLinks = new Map();
  document.querySelectorAll(".nav-links a[href^='#']").forEach((link) => {
    const id = link.getAttribute("href").slice(1);
    if (id) sectionLinks.set(id, link);
  });
  if (sectionLinks.size && "IntersectionObserver" in window) {
    const sectionObserver = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        const link = sectionLinks.get(entry.target.id);
        if (!link) return;
        document.querySelectorAll(".nav-links a[aria-current]").forEach((other) => other.removeAttribute("aria-current"));
        link.setAttribute("aria-current", "location");
      });
    }, { rootMargin: "-28% 0px -58% 0px", threshold: 0 });
    sectionLinks.forEach((_, id) => {
      const section = document.getElementById(id);
      if (section) sectionObserver.observe(section);
    });

    // The hero and the closing download have no nav link: clear the marker there rather than leave the last section lit.
    const clearCurrent = () => {
      document.querySelectorAll(".nav-links a[aria-current]").forEach((link) => link.removeAttribute("aria-current"));
    };
    const clearObserver = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) clearCurrent();
    }, { rootMargin: "-24% 0px -60% 0px", threshold: 0 });
    [document.querySelector(".hero"), document.getElementById("download")].forEach((element) => {
      if (element) clearObserver.observe(element);
    });
  }

  // The live workflow: a replayable sequence, manual steps, and an approval that ships the demo.
  const workflow = document.querySelector("[data-workflow-stage]");
  if (workflow) {
    const workflowSteps = ["speak", "note", "distill", "understand", "assign", "wake"];
    const stepButtons = Array.from(document.querySelectorAll("[data-workflow-step]"));
    const replay = document.querySelector("[data-workflow-replay]");
    const caption = document.querySelector("[data-workflow-caption]");
    const progress = document.querySelector("[data-workflow-progress]");
    const liveLabel = document.querySelector("[data-workflow-live]");
    const counter = document.querySelector("[data-workflow-counter]");
    const linkLabel = document.querySelector("[data-workflow-link]");
    const specCount = document.querySelector("[data-workflow-spec-count]");
    const specStatus = document.querySelector("[data-workflow-spec-status]");
    const boardLive = document.querySelector("[data-workflow-board-live]");
    const boardSub = document.querySelector("[data-workflow-board-sub]");
    const agentStatuses = Array.from(document.querySelectorAll("[data-agent-status]"));
    const progressLabels = Array.from(document.querySelectorAll(".card-progress em"));
    const approve = document.querySelector("[data-workflow-approve]");
    const decline = document.querySelector("[data-workflow-decline]");
    const distill = document.querySelector("[data-workflow-distill]");
    const counts = {
      ready: document.querySelector('[data-board-col="ready"] .col-head span'),
      working: document.querySelector('[data-board-col="working"] .col-head span'),
      review: document.querySelector('[data-board-col="review"] .col-head span'),
      done: document.querySelector('[data-board-col="done"] .col-head span')
    };

    const copy = {
      speak: { caption: "Speak · A product idea, said out loud.", counter: "1 idea", link: "Speak", spec: "Draft", specStatus: "Draft", board: "Waiting for spec", boardSub: "Pricing page · 0 cards", counts: [0, 0, 0, 0] },
      note: { caption: "Note · The idea becomes a Markdown spec you can edit.", counter: "1 spec", link: "Note", spec: "Draft · 3 work items", specStatus: "Draft", board: "Waiting for distill", boardSub: "Pricing page · 0 cards", counts: [0, 0, 0, 0] },
      distill: { caption: "Distill · The spec becomes cards, each with its source and dependencies.", counter: "5 cards", link: "Distill", spec: "Distilled · 3 work items", specStatus: "Distilled", board: "Cards ready", boardSub: "Pricing page · 5 cards", counts: [2, 3, 0, 0] },
      understand: { caption: "Understand · The work is mapped: what waits for what, and who can do it.", counter: "3 work items · 1 dependency", link: "Understand", spec: "3 work items · 1 dependency", specStatus: "Understood", board: "Dependencies mapped", boardSub: "Pricing page · 5 cards", counts: [2, 3, 0, 0] },
      assign: { caption: "Assign · Cards go to agents that can pick them up and report back.", counter: "3 agents", link: "Assign", spec: "Assigned to agents", specStatus: "Assigned", board: "Agents active", boardSub: "Pricing page · 5 cards", counts: [2, 3, 0, 0] },
      wake: { caption: "Wake · Agents work in parallel, ask when they are stuck, and hand it back for review.", counter: "1 approval", link: "Wake", spec: "In progress", specStatus: "In progress", board: "1 approval", boardSub: "Pricing page · 5 cards", counts: [2, 3, 0, 0] },
      approved: { caption: "Approved · You made the call. The page ships.", counter: "Shipped · 2:14 PM", link: "Ship", spec: "Shipped", specStatus: "Shipped", board: "Shipped", boardSub: "Pricing page · 4 cards", counts: [0, 2, 1, 1] }
    };

    let timer = null;
    let approvalTimer = null;
    let started = false;
    let userInteracted = false;

    const clearTimers = () => {
      if (timer) clearTimeout(timer);
      if (approvalTimer) clearTimeout(approvalTimer);
      timer = null;
      approvalTimer = null;
    };

    const setStep = (step, nextApproval = "question") => {
      const approved = nextApproval === "approved";
      const state = copy[approved ? "approved" : step] || copy.speak;
      workflow.dataset.step = step;
      workflow.dataset.approval = nextApproval;
      stepButtons.forEach((button) => {
        if (button.dataset.workflowStep === step) button.setAttribute("aria-current", "step");
        else button.removeAttribute("aria-current");
      });
      if (caption) caption.textContent = state.caption;
      if (progress) progress.style.width = `${Math.round(((workflowSteps.indexOf(step) + 1) / workflowSteps.length) * 100)}%`;
      if (liveLabel) liveLabel.textContent = approved ? "Shipped" : "Live workflow";
      if (counter) counter.textContent = state.counter;
      if (linkLabel) linkLabel.textContent = state.link;
      if (specCount) specCount.textContent = state.spec;
      if (specStatus) specStatus.textContent = state.specStatus;
      if (boardLive) boardLive.textContent = state.board;
      if (boardSub) boardSub.textContent = state.boardSub;
      if (counts.ready) counts.ready.textContent = String(state.counts[0]);
      if (counts.working) counts.working.textContent = String(state.counts[1]);
      if (counts.review) counts.review.textContent = String(state.counts[2]);
      if (counts.done) counts.done.textContent = String(state.counts[3]);
      const statuses = approved ? ["done", "done", "done"] : (step === "assign" || step === "wake" ? ["writing", "reviewing", "QA"] : ["waiting", "waiting", "waiting"]);
      agentStatuses.forEach((status, index) => { status.textContent = statuses[index] || "waiting"; });
      const percentages = approved ? ["100%", "100%", "100%"] : (step === "wake" ? ["86%", "74%", "96%"] : (step === "assign" ? ["68%", "52%", "81%"] : ["0%", "0%", "0%"]));
      progressLabels.forEach((label, index) => { label.textContent = percentages[index] || "0%"; });
    };

    const play = () => {
      clearTimers();
      userInteracted = false;
      started = true;
      setStep("speak", "question");
      if (reduceMotion) {
        setStep("wake", "approved");
        return;
      }
      const sequence = [
        ["note", 2600],
        ["distill", 2400],
        ["understand", 2200],
        ["assign", 2200],
        ["wake", 2400]
      ];
      let index = 0;
      const next = () => {
        if (index >= sequence.length) return;
        const [step, delay] = sequence[index++];
        timer = setTimeout(() => {
          setStep(step, "question");
          if (step === "wake") {
            approvalTimer = setTimeout(() => setStep("wake", "approved"), 2200);
          } else {
            next();
          }
        }, delay);
      };
      next();
    };

    setStep("speak", "question");
    if (reduceMotion) {
      setStep("wake", "approved");
      started = true;
    } else if ("IntersectionObserver" in window) {
      const workflowObserver = new IntersectionObserver((entries, observer) => {
        if (started) return;
        if (entries.some((entry) => entry.isIntersecting) && !userInteracted) {
          started = true;
          play();
          observer.disconnect();
        }
      }, { threshold: 0.22 });
      workflowObserver.observe(workflow.closest(".workflow-shell") || workflow);
    } else {
      play();
    }

    stepButtons.forEach((button) => {
      button.addEventListener("click", () => {
        clearTimers();
        userInteracted = true;
        started = true;
        setStep(button.dataset.workflowStep, "question");
      });
    });

    if (replay) {
      replay.addEventListener("click", () => {
        clearTimers();
        started = true;
        play();
      });
    }
    if (approve) {
      approve.addEventListener("click", () => {
        clearTimers();
        userInteracted = true;
        setStep("wake", "approved");
      });
    }
    if (decline) {
      decline.addEventListener("click", () => {
        clearTimers();
        userInteracted = true;
        setStep("assign", "question");
        if (caption) caption.textContent = "Decline · Cursor will revise the table.";
      });
    }
    if (distill) {
      distill.addEventListener("click", () => {
        clearTimers();
        userInteracted = true;
        setStep("distill", "question");
      });
    }
  }

  // The tour opens over the page; without JavaScript the link opens the video itself.
  const tour = document.getElementById("tour");
  const tourVideo = document.getElementById("tour-video");
  document.querySelectorAll("[data-tour]").forEach((link) => {
    link.addEventListener("click", (event) => {
      if (!tour || typeof tour.showModal !== "function") return;
      event.preventDefault();
      if (!tour.open) tour.showModal();
    });
  });
  if (tour) {
    const closeTour = () => { if (tourVideo) tourVideo.pause(); };
    tour.addEventListener("close", closeTour);
    tour.addEventListener("cancel", closeTour);
    tour.addEventListener("click", (event) => {
      if (event.target === tour) tour.close();
    });
  }
})();
