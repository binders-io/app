// Binders site: the page that fills itself, the dictation demo, the Ask demo, and the nav. No libraries.
// Everything is readable before this runs; motion only adds to it, and none of it runs with reduced motion.
(() => {
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const icon = (name) => `<svg class="i" aria-hidden="true"><use href="#i-${name}"/></svg>`;
  const escape = (text) => text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

  // Waveform bars for every dictation pill.
  const fillWave = (pill) => {
    pill.innerHTML = "";
    for (let i = 0; i < 26; i++) {
      const bar = document.createElement("i");
      bar.style.setProperty("--i", i);
      bar.style.setProperty("--h", Math.abs(Math.sin(i * 0.55) * Math.cos(i * 0.21)).toFixed(2));
      pill.appendChild(bar);
    }
  };
  document.querySelectorAll(".flow-pill.wave").forEach(fillWave);

  // Runs a demo loop only while its element is on screen and the tab is visible.
  const whileVisible = (element, loop) => {
    if (!element || reduced) return;
    let visible = false;
    let running = false;
    const gate = { get open() { return visible && !document.hidden; } };
    const wait = async () => { while (!gate.open) await sleep(250); };
    const kick = () => {
      if (running || !gate.open) return;
      running = true;
      loop(wait).finally(() => { running = false; });
    };
    new IntersectionObserver((entries) => {
      visible = entries.some((entry) => entry.isIntersecting);
      kick();
    }, { threshold: 0.25 }).observe(element);
    document.addEventListener("visibilitychange", kick);
  };

  // A flow bar: Binders' caption above its pill, in one of the app's states.
  const flowBar = (root) => {
    const caption = root.querySelector(".flow-caption");
    const pill = root.querySelector(".flow-pill");
    const set = (kind, html) => {
      pill.className = `flow-pill ${kind}`;
      if (kind === "wave") fillWave(pill);
      else if (kind === "processing") pill.innerHTML = "<i style='--i:0'></i><i style='--i:1'></i><i style='--i:2'></i>";
      else pill.innerHTML = html;
    };
    return {
      caption(html) {
        caption.hidden = html == null;
        if (html != null) caption.innerHTML = html;
      },
      listen() { root.classList.remove("quiet"); set("wave"); },
      quiet() { root.classList.add("quiet"); },
      processing() { set("processing"); },
      toast(symbol, text) { set("toast", `${icon(symbol)}<span>${escape(text)}</span>`); },
      meeting(time) { set("meeting", `<span class="rec"></span><span class="t">${time}</span><span class="notes-button">Notes</span><span class="stop"><i></i></span>`); },
      ask(text) { set("toast", `${icon("spark")}<span>${escape(text)}</span>`); },
      pill,
    };
  };

  // Speaks a sentence into a caption, word by word, the way the live preview arrives.
  const speak = async (bar, words, wait) => {
    bar.listen();
    for (let count = 1; count <= words.length; count++) {
      await wait();
      bar.caption(escape(words.slice(0, count).join(" ")));
      await sleep(140 + Math.random() * 120);
    }
  };

  // The hero page: every few seconds something new is said, heard, written or asked, and lands on the page.
  const entries = document.getElementById("entries");
  const heroFlow = document.getElementById("hero-flow");
  if (entries && heroFlow) {
    const bar = flowBar(heroFlow);
    const glyphs = { say: "mic", todo: "todo", calendar: "calendar", hear: "people", write: "hand", find: "spark" };
    const pool = [
      { kind: "say", glyph: "todo", said: "add to-do call Amara tomorrow about the debrief",
        text: "Call Amara about the debrief", due: "tomorrow", meta: "To-do added by voice" },
      { kind: "hear", meeting: "31:07", owner: "Priya",
        text: "Confirm the annual discount with finance", meta: "Action item · Launch readiness review" },
      { kind: "write", toast: "Promise noted: Send Delphine the sandbox link · tomorrow",
        text: "Send Delphine the sandbox link", due: "tomorrow", meta: "Promised in Microsoft Outlook · 8:07 AM" },
      { kind: "find", ask: "What did Delphine say about the import tool?",
        text: "Delphine wants to see the import tool on her real export before deciding on a trial.", meta: "Answer · 2 sources" },
      { kind: "say", glyph: "calendar", said: "add lunch with Jonas Monday at noon to my calendar",
        text: "Lunch with Jonas", due: "Mon 12:00 PM", meta: "Added to your calendar by voice" },
      { kind: "hear", meeting: "12:48", owner: "Jonas",
        text: "Get support to review the last two onboarding emails", meta: "Action item · Launch readiness review" },
      { kind: "say", said: "so the pricing copy is final but the comparison table is not",
        text: "The pricing copy is final, but the comparison table is not.", meta: "Dictated into Mail" },
      { kind: "write", toast: "Ask noted: Share the beta list export · Monday",
        text: "Share the beta list export", owner: "Jonas", due: "Monday", meta: "Asked in Microsoft Teams · 11:55 AM" },
    ];

    const render = (entry) => {
      const item = document.createElement("li");
      item.className = "entry arriving";
      item.dataset.kind = entry.kind;
      item.style.setProperty("--bar", `${58 + Math.round(Math.random() * 30)}%`);
      const owner = entry.owner ? `<span class="owner">${escape(entry.owner)}</span> ` : "";
      const due = entry.due ? ` <span class="due">${escape(entry.due)}</span>` : "";
      item.innerHTML = `<span class="glyph" aria-hidden="true">${icon(entry.glyph || glyphs[entry.kind])}</span>
        <div class="entry-body"><p class="entry-text">${owner}${escape(entry.text)}${due}</p><p class="entry-meta">${escape(entry.meta)}</p></div>`;
      return item;
    };

    const land = (entry) => {
      const item = render(entry);
      entries.prepend(item);
      const last = entries.lastElementChild;
      if (entries.children.length > 4 && last) {
        last.classList.add("leaving");
        setTimeout(() => last.remove(), 500);
      }
      setTimeout(() => item.classList.remove("arriving"), 1400);
    };

    whileVisible(heroFlow.closest(".sheet-stage"), async (wait) => {
      await sleep(1600);
      for (let index = 0; ; index++) {
        await wait();
        const entry = pool[index % pool.length];
        if (entry.said) {
          await speak(bar, entry.said.split(" "), wait);
          await sleep(500);
          bar.caption(null);
          bar.processing();
          await sleep(700);
          if (entry.glyph === "todo") bar.toast("todo", `To-do added: ${entry.text} · ${entry.due}`);
          else if (entry.glyph === "calendar") bar.toast("calendar", `Added to Work: ${entry.text} · ${entry.due}`);
          else bar.quiet();
        } else if (entry.meeting) {
          bar.caption(null);
          bar.meeting(entry.meeting);
          await sleep(1400);
        } else if (entry.toast) {
          bar.caption(null);
          bar.toast("hand", entry.toast);
        } else if (entry.ask) {
          bar.caption(null);
          bar.ask(entry.ask);
          await sleep(1300);
        }
        land(entry);
        await sleep(3400);
      }
    });
  }

  // Say it: a message written by voice, then a to-do and a calendar event by Command Mode.
  const compose = document.getElementById("compose");
  if (compose) {
    const bar = flowBar(document.getElementById("compose-flow"));
    const mode = document.getElementById("compose-mode");
    const field = document.getElementById("compose-text");
    const thread = compose.querySelector(".thread");
    const scenes = [
      { mode: "Dictation · <kbd>fn</kbd>", said: "so I think we should do the review at 2 actually no 3 pm tomorrow and bring the slides",
        struck: "2 actually no", lands: "I think we should do the review at 3 pm tomorrow and bring the slides." },
      { mode: "Command Mode · <kbd>fn</kbd><kbd>⌃</kbd>", said: "add it to my calendar",
        toast: ["calendar", "Added to Work: Launch review · Tomorrow, 3:00 PM"] },
      { mode: "Command Mode · <kbd>fn</kbd><kbd>⌃</kbd>", said: "add to-do send Priya the pricing table by Tuesday",
        toast: ["todo", "To-do added: Send Priya the pricing table · Tuesday"] },
      { mode: "Dictation · <kbd>fn</kbd>", said: "um and can someone from support join us too",
        struck: "um", lands: "Can someone from support join us too?" },
    ];
    const send = () => {
      const text = field.textContent.trim();
      if (!text) return;
      const bubble = document.createElement("p");
      bubble.className = "msg mine";
      bubble.innerHTML = `<b>You</b>${escape(text)}`;
      thread.appendChild(bubble);
      while (thread.children.length > 2) thread.firstElementChild.remove();
      field.textContent = "";
    };

    whileVisible(compose, async (wait) => {
      // The page shows the finished message until the demo is on screen; then it starts from an empty field.
      field.textContent = "";
      bar.caption(null);
      await sleep(900);
      for (let index = 0; ; index++) {
        await wait();
        const scene = scenes[index % scenes.length];
        mode.innerHTML = scene.mode;
        if (index > 0 && scene.lands) send();
        const words = scene.said.split(" ");
        await speak(bar, words, wait);
        if (scene.struck) {
          const plain = escape(scene.said).replace(escape(scene.struck), `<s>${escape(scene.struck)}</s>`);
          bar.caption(plain);
        }
        await sleep(700);
        bar.processing();
        await sleep(650);
        bar.caption(null);
        if (scene.lands) {
          bar.listen();
          bar.quiet();
          field.textContent = scene.lands;
          field.classList.remove("landed");
          void field.offsetWidth;
          field.classList.add("landed");
        } else {
          bar.toast(...scene.toast);
        }
        await sleep(2800);
      }
    });
  }

  // Hear it: the meeting pill keeps time while it is on screen.
  const timer = document.getElementById("meeting-timer");
  if (timer && !reduced) {
    let seconds = 47 * 60 + 12;
    let visible = false;
    new IntersectionObserver((list) => { visible = list.some((entry) => entry.isIntersecting); }).observe(timer);
    setInterval(() => {
      if (!visible || document.hidden) return;
      seconds++;
      timer.textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
    }, 1000);
  }

  // Find it: click a question, watch the answer arrive. These are Binders' real answers over the demo data.
  const ask = document.getElementById("ask-demo");
  if (ask) {
    const answers = [
      { q: "What did I promise Jonas this week?",
        html: "<p>You promised Jonas the following this week:</p><ul><li>The final launch checklist by Friday <sup>[1][2][3]</sup>.</li><li>To loop in support on the last two onboarding emails today <sup>[1]</sup>.</li></ul>",
        sources: [["writing", "To Jonas Lindqvist", "Sep 25 · Microsoft Teams"], ["meeting", "Launch readiness review", "Sep 24 · transcript at 00:04"], ["meeting", "Launch readiness review", "Sep 24 · Summary"]] },
      { q: "What did I say about the onboarding emails in the launch review?",
        html: "<p>In the launch review, you stated that five onboarding emails have been drafted, with three having completed the review process and two still waiting on support <sup>[2]</sup>.</p>",
        sources: [["meeting", "Launch readiness review", "Sep 24 · Summary"], ["meeting", "Launch readiness review", "Sep 24 · transcript at 00:04"], ["note", "Launch checklist", "Sep 24"]] },
      { q: "What did we decide about annual plans?",
        html: "<p>It was decided that:</p><ul><li>The pricing page will feature three plans with the annual toggle turned on by default <sup>[1]</sup>.</li><li>Annual plans will launch with a 15% discount <sup>[2]</sup>.</li></ul>",
        sources: [["meeting", "Pricing page walkthrough", "Sep 21 · Summary"], ["meeting", "Launch readiness review", "Sep 24 · Summary"]] },
      { q: "What did Delphine say about the import tool?",
        html: "<p>Delphine wants to see the import tool working on her real export before deciding on a trial <sup>[1][2]</sup>.</p>",
        sources: [["meeting", "Interview: Delphine at Orchard Labs", "Sep 19 · Summary"], ["writing", "To Delphine Marchetti", "Sep 25 · Microsoft Outlook"]] },
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
      // The answer reads in word by word, the way a local model streams it.
      const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
      const nodes = [];
      while (walker.nextNode()) nodes.push([walker.currentNode, walker.currentNode.textContent]);
      nodes.forEach(([node]) => { node.textContent = ""; });
      for (const [node, text] of nodes) {
        for (const word of text.split(/(\s+)/)) {
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
    // The first time the demo comes into view, it answers a question on its own.
    if (!reduced && "IntersectionObserver" in window) {
      const once = new IntersectionObserver((list) => {
        if (list.some((entry) => entry.isIntersecting)) {
          once.disconnect();
          setTimeout(() => { if (run === 0) play(2); }, 500);
        }
      }, { threshold: 0.5 });
      once.observe(ask);
    }
  }

  // The nav: frosted once the page moves, a progress line in the colour of the divider you are reading, and the
  // matching link marked.
  const nav = document.querySelector(".nav");
  const links = [...document.querySelectorAll('.nav-links a[href^="#"]')];
  const sections = links.map((link) => document.querySelector(link.getAttribute("href"))).filter(Boolean);
  let ticking = false;
  const update = () => {
    ticking = false;
    const y = window.scrollY;
    nav.classList.toggle("scrolled", y > 8);
    const max = document.documentElement.scrollHeight - window.innerHeight;
    nav.style.setProperty("--progress", max > 0 ? (y / max).toFixed(4) : "0");
    const line = y + nav.offsetHeight + 80;
    let current = null;
    for (const section of sections) if (section.offsetTop <= line) current = section;
    const colour = current ? getComputedStyle(current).getPropertyValue("--tab").trim() : "";
    nav.style.setProperty("--current", colour || "rgba(255,255,255,0.6)");
    links.forEach((link) => link.setAttribute("aria-current", current !== null && link.getAttribute("href") === `#${current.id}` ? "location" : "false"));
  };
  if (nav) {
    update();
    window.addEventListener("scroll", () => { if (!ticking) { ticking = true; requestAnimationFrame(update); } }, { passive: true });
    window.addEventListener("resize", update, { passive: true });
  }
})();
