// Binders site: the flow bar demo, the nav hairline, and gentle reveals. No libraries.
(() => {
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  // Waveform bars for the dictation pill.
  const pill = document.getElementById("flow-pill");
  if (pill) {
    for (let i = 0; i < 26; i++) {
      const bar = document.createElement("i");
      bar.style.setProperty("--i", i);
      bar.style.setProperty("--h", Math.abs(Math.sin(i * 0.55) * Math.cos(i * 0.21)).toFixed(2));
      pill.appendChild(bar);
    }
  }

  // The caption speaks a sentence word by word, then Binders notes the promise in it.
  const flow = document.getElementById("flow");
  const caption = document.getElementById("flow-caption");
  const hand = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 11V5.5a1.5 1.5 0 0 1 3 0V10m0-5.5v-1a1.5 1.5 0 0 1 3 0V10m0-4.5a1.5 1.5 0 0 1 3 0V12m0-3a1.5 1.5 0 0 1 3 0v5.5A6.5 6.5 0 0 1 13.5 21h-1.2a6 6 0 0 1-4.7-2.3l-3.2-4.1a1.6 1.6 0 0 1 2.4-2.1L8 13.8"/></svg>';
  const lines = [
    { say: "I'll send you the final launch checklist by Friday", note: "Promise noted: Send Jonas the final launch checklist · Friday" },
    { say: "Let's move the review to Thursday so support can join", note: null },
    { say: "Can you share the beta list export before Monday?", note: "Ask noted: Share the beta list export · Monday" },
  ];

  const show = (text, withIcon) => {
    caption.innerHTML = (withIcon ? hand : "") + "<span></span>";
    caption.classList.toggle("toast", withIcon);
    caption.querySelector("span").textContent = text;
  };

  const speak = async () => {
    for (let index = 0; ; index++) {
      const { say, note } = lines[index % lines.length];
      const words = say.split(" ");
      flow.classList.remove("quiet");
      for (let count = 1; count <= words.length; count++) {
        show(words.slice(0, count).join(" "), false);
        await sleep(150 + Math.random() * 130);
      }
      await sleep(900);
      flow.classList.add("quiet");
      if (note) {
        show(note, true);
        await sleep(3200);
      } else {
        await sleep(1200);
      }
      await sleep(400);
    }
  };

  if (flow && caption) {
    if (reduced) {
      flow.classList.add("quiet");
    } else {
      speak();
    }
  }

  // Ask: click a question, watch the answer arrive. These are Binders' real answers over the demo data.
  const ask = document.getElementById("ask-demo");
  if (ask) {
    const answers = [
      { q: "What did I promise Jonas this week?",
        html: "<p>You promised Jonas the following this week:</p><ul><li>The final launch checklist by Friday <sup>[1][2][3]</sup>.</li><li>To loop in support on the last two onboarding emails today <sup>[1]</sup>.</li></ul>",
        sources: [["writing", "To Jonas Lindqvist", "Sep 19 · Microsoft Teams"], ["meeting", "Launch readiness review", "Sep 18 · transcript at 00:04"], ["meeting", "Launch readiness review", "Sep 18 · Summary"]] },
      { q: "What did I say about the onboarding emails in the launch review?",
        html: "<p>In the launch review, you stated that five onboarding emails have been drafted, with three having completed the review process and two still waiting on support <sup>[2]</sup>.</p>",
        sources: [["meeting", "Launch readiness review", "Sep 18 · Summary"], ["meeting", "Launch readiness review", "Sep 18 · transcript at 00:04"], ["note", "Launch checklist", "Sep 18"]] },
      { q: "What did we decide about annual plans?",
        html: "<p>It was decided that:</p><ul><li>The pricing page will feature three plans with the annual toggle turned on by default <sup>[1]</sup>.</li><li>Annual plans will launch with a 15% discount <sup>[2]</sup>.</li></ul>",
        sources: [["meeting", "Pricing page walkthrough", "Sep 15 · Summary"], ["meeting", "Launch readiness review", "Sep 18 · Summary"]] },
      { q: "What did Delphine say about the import tool?",
        html: "<p>Delphine wants to see the import tool working on her real export before deciding on a trial <sup>[1][2]</sup>.</p>",
        sources: [["meeting", "Interview: Delphine at Orchard Labs", "Sep 13 · Summary"], ["writing", "To Delphine Marchetti", "Sep 19 · Microsoft Outlook"]] },
    ];
    const question = document.getElementById("ask-question");
    const body = document.getElementById("answer-body");
    const list = document.getElementById("answer-sources");
    const state = document.getElementById("answer-state");
    const chips = ask.querySelectorAll(".chip");
    let run = 0;

    const fill = (entry, hidden) => {
      body.innerHTML = entry.html;
      list.innerHTML = "";
      for (const [kind, title, meta] of entry.sources) {
        const item = document.createElement("li");
        item.dataset.kind = kind;
        if (hidden) item.classList.add("hide");
        const name = document.createElement("span");
        name.textContent = title;
        const detail = document.createElement("em");
        detail.textContent = meta;
        item.append(name, detail);
        list.appendChild(item);
      }
    };

    const play = async (index) => {
      const entry = answers[index];
      const mine = ++run;
      chips.forEach((chip, i) => chip.setAttribute("aria-pressed", String(i === index)));
      if (reduced) {
        question.textContent = entry.q;
        fill(entry, false);
        return;
      }
      ask.classList.add("typing");
      question.textContent = "";
      body.innerHTML = "";
      list.innerHTML = "";
      state.textContent = "Searching meetings, notes and messages…";
      for (let count = 1; count <= entry.q.length; count++) {
        if (mine !== run) return;
        question.textContent = entry.q.slice(0, count);
        await sleep(14);
      }
      ask.classList.remove("typing");
      await sleep(650);
      if (mine !== run) return;
      state.textContent = "Answer";
      fill(entry, true);
      // Let the answer read in word by word, the way a local model streams it.
      const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
      const nodes = [];
      while (walker.nextNode()) nodes.push([walker.currentNode, walker.currentNode.textContent]);
      nodes.forEach(([node]) => { node.textContent = ""; });
      for (const [node, text] of nodes) {
        const words = text.split(/(\s+)/);
        for (const word of words) {
          if (mine !== run) return;
          node.textContent += word;
          if (word.trim()) await sleep(34);
        }
      }
      for (const item of list.children) {
        if (mine !== run) return;
        await sleep(120);
        item.classList.remove("hide");
      }
    };

    chips.forEach((chip, index) => chip.addEventListener("click", () => play(index)));
  }

  // Hairline under the nav once the page has moved.
  const nav = document.querySelector(".nav");
  const onScroll = () => nav && nav.classList.toggle("scrolled", window.scrollY > 8);
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  // Reveal sections as they arrive. With reduced motion or no observer support, everything is simply visible.
  const targets = document.querySelectorAll(".feature .copy, .feature .visual, .ledger .col, .steps li, .fact");
  if (!reduced && "IntersectionObserver" in window) {
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add("in");
          observer.unobserve(entry.target);
        }
      }
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    targets.forEach((element) => {
      element.classList.add("reveal");
      observer.observe(element);
    });
  }
})();
