import { apiInitializer } from "discourse/lib/api";

const AUDIO_EXTENSIONS = [".mp3", ".m4a", ".wav", ".ogg", ".aac"];
const JSON_EXTENSIONS = [".json"];

export default apiInitializer((api) => {
  api.decorateCookedElement(
    async (element) => {
      if (element.dataset.audioSyncProcessed) {
        return;
      }

      const jsonLink = findLinkByExtension(element, JSON_EXTENSIONS);
      const audio = findOrCreateAudio(element);

      if (!audio || !jsonLink) {
        return;
      }

      element.dataset.audioSyncProcessed = "true";
      hideAssetLink(jsonLink);

      let alignment;

      try {
        const response = await fetch(jsonLink.href);

        if (!response.ok) {
          debugWarn(
            "AudioSync: JSON fetch failed:",
            response.status,
            jsonLink.href
          );
          return;
        }

        const data = await response.json();
        alignment = data.alignment || (data.characters ? data : null);
      } catch (error) {
        console.error("AudioSync fetch error:", error);
        return;
      }

      if (!alignment) {
        return;
      }

      const audioWords = parseAlignment(alignment);
      if (!audioWords.length) {
        return;
      }

      const domTokens = tokenizeDOM(element);
      if (!domTokens.length) {
        return;
      }

      const matches = alignTokens(audioWords, domTokens, 20);
      wrapMatches(matches);

      debugLog(
        `AudioSync: matched ${matches.length}/${audioWords.length} audio words; DOM tokens: ${domTokens.length}`
      );

      const spans = Array.from(element.querySelectorAll(".speaking-word")).map(
        (span) => ({
          el: span,
          start: parseFloat(span.dataset.start),
          end: parseFloat(span.dataset.end),
        })
      );

      let isLooping = false;
      let rafId = null;

      const renderLoop = () => {
        if (audio.paused) {
          isLooping = false;
          return;
        }

        const currentTime = audio.currentTime;

        spans.forEach((span) => {
          if (currentTime >= span.start && currentTime < span.end) {
            span.el.classList.add("active");
          } else {
            span.el.classList.remove("active");
          }
        });

        rafId = requestAnimationFrame(renderLoop);
      };

      const startLoop = () => {
        if (!isLooping) {
          isLooping = true;
          renderLoop();
        }
      };

      audio.addEventListener("play", startLoop);
      audio.addEventListener("playing", startLoop);
      audio.addEventListener("timeupdate", startLoop);

      audio.addEventListener("pause", () => {
        isLooping = false;
        if (rafId) {
          cancelAnimationFrame(rafId);
        }
      });

      audio.addEventListener("ended", () => {
        isLooping = false;
        if (rafId) {
          cancelAnimationFrame(rafId);
        }

        spans.forEach((span) => span.el.classList.remove("active"));
      });

      element.addEventListener("click", (event) => {
        const target = event.target;

        if (target?.classList?.contains("speaking-word")) {
          const start = parseFloat(target.dataset.start);

          if (!Number.isNaN(start)) {
            const preroll = settings.seek_preroll_seconds ?? 0.04;
            audio.currentTime = Math.max(0, start - preroll);
            audio.play();
          }
        }
      });
    },
    { id: "audio-sync" }
  );
});

function debugLog(...args) {
  if (settings.debug_logging) {
    console.log(...args);
  }
}

function debugWarn(...args) {
  if (settings.debug_logging) {
    console.warn(...args);
  }
}

function findOrCreateAudio(element) {
  const existingAudio = element.querySelector("audio");
  if (existingAudio) {
    return existingAudio;
  }

  const audioLink = findLinkByExtension(element, AUDIO_EXTENSIONS);
  if (!audioLink) {
    return null;
  }

  const audio = document.createElement("audio");
  audio.controls = true;
  audio.preload = "metadata";
  audio.src = audioLink.href;
  audio.className = "audio-sync-player";

  insertAfterAssetLink(audioLink, audio);
  hideAssetLink(audioLink);

  return audio;
}

function findLinkByExtension(element, extensions) {
  const links = Array.from(element.querySelectorAll("a[href]"));

  return links.find((link) => urlPathHasExtension(link.href, extensions));
}

function urlPathHasExtension(rawUrl, extensions) {
  try {
    const url = new URL(rawUrl, window.location.href);
    const path = decodeURIComponent(url.pathname).toLowerCase();

    return extensions.some((extension) => path.endsWith(extension));
  } catch {
    return false;
  }
}

function hideAssetLink(link) {
  link.classList.add("audio-sync-asset");

  const onebox = link.closest(".onebox, aside.onebox");

  if (onebox) {
    onebox.classList.add("audio-sync-asset");
    onebox.style.display = "none";
  } else {
    link.style.display = "none";
  }
}

function insertAfterAssetLink(link, node) {
  const onebox = link.closest(".onebox, aside.onebox");
  const anchor = onebox || link;

  anchor.insertAdjacentElement("afterend", node);
}

function normalize(str) {
  return str
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/['\u2019\u201b\u00b4`]/g, "")
    .replace(/[^\p{L}\p{N}]+/gu, "")
    .toLowerCase();
}

function parseAlignment(alignment) {
  const out = [];

  if (Array.isArray(alignment.words)) {
    alignment.words.forEach((word) => {
      const text = word.text || word.word || word.token;
      const start =
        word.start ??
        word.start_time ??
        word.start_time_seconds ??
        word.startTime;
      const end =
        word.end ?? word.end_time ?? word.end_time_seconds ?? word.endTime;

      if (
        text &&
        typeof start === "number" &&
        typeof end === "number" &&
        !Number.isNaN(start) &&
        !Number.isNaN(end)
      ) {
        out.push({
          text,
          start,
          end,
          norm: normalize(text),
        });
      }
    });

    return out;
  }

  const chars = alignment.characters || [];
  const starts = alignment.character_start_times_seconds || [];
  const ends = alignment.character_end_times_seconds || [];

  let currentWord = "";
  let start = null;

  for (let index = 0; index < chars.length; index++) {
    const character = chars[index];

    if (isWordChar(character)) {
      if (start === null) {
        start = starts[index];
      }
      currentWord += character;
    } else if (currentWord) {
      out.push({
        text: currentWord,
        start,
        end: ends[index - 1],
        norm: normalize(currentWord),
      });

      currentWord = "";
      start = null;
    }
  }

  if (currentWord) {
    out.push({
      text: currentWord,
      start,
      end: ends[ends.length - 1],
      norm: normalize(currentWord),
    });
  }

  return out;
}

function isWordChar(character) {
  return /\p{L}|\p{N}/u.test(character);
}

function tokenizeDOM(root) {
  const tokens = [];

  const rejectTags = new Set([
    "CODE",
    "PRE",
    "KBD",
    "BUTTON",
    "SCRIPT",
    "STYLE",
    "TEXTAREA",
    "INPUT",
    "SELECT",
    "OPTION",
  ]);

  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: (node) => {
      const parent = node.parentElement;
      if (!parent) {
        return NodeFilter.FILTER_REJECT;
      }

      if (rejectTags.has(parent.tagName)) {
        return NodeFilter.FILTER_REJECT;
      }

      const assetLink = parent.closest("a[href]");

      if (
        parent.closest("a.attachment") ||
        parent.closest("a.audio-sync-asset") ||
        parent.closest(".audio-sync-asset") ||
        parent.closest("audio") ||
        parent.closest(".audio-sync-player") ||
        parent.closest(".onebox") ||
        parent.closest(".lightbox-wrapper") ||
        parent.closest(".spoiler") ||
        (assetLink &&
          (urlPathHasExtension(assetLink.href, JSON_EXTENSIONS) ||
            urlPathHasExtension(assetLink.href, AUDIO_EXTENSIONS)))
      ) {
        return NodeFilter.FILTER_REJECT;
      }

      if (parent.offsetParent === null) {
        return NodeFilter.FILTER_REJECT;
      }

      return NodeFilter.FILTER_ACCEPT;
    },
  });

  let node;
  let globalIdx = 0;
  const wordRe = /[\p{L}\p{N}]+/gu;

  while ((node = walker.nextNode())) {
    const text = node.textContent;
    let match;

    while ((match = wordRe.exec(text)) !== null) {
      const raw = match[0];

      tokens.push({
        node,
        start: match.index,
        end: match.index + raw.length,
        raw,
        norm: normalize(raw),
        idx: globalIdx++,
      });
    }
  }

  return tokens;
}

function alignTokens(audioWords, domTokens, windowSize = 20) {
  const matches = [];

  let i = 0;
  let j = 0;

  while (i < audioWords.length && j < domTokens.length) {
    const audioWord = audioWords[i];
    const domToken = domTokens[j];

    if (audioWord.norm && audioWord.norm === domToken.norm) {
      matches.push({
        audio: audioWord,
        dom: domToken,
      });

      i++;
      j++;
      continue;
    }

    let foundDom = -1;

    for (
      let offset = 1;
      offset <= windowSize && j + offset < domTokens.length;
      offset++
    ) {
      if (domTokens[j + offset].norm === audioWord.norm) {
        foundDom = j + offset;
        break;
      }
    }

    if (foundDom !== -1) {
      j = foundDom;
      continue;
    }

    i++;
  }

  return matches;
}

function wrapMatches(matches) {
  const byNode = new Map();

  matches.forEach((match) => {
    const node = match.dom.node;

    if (!byNode.has(node)) {
      byNode.set(node, []);
    }

    byNode.get(node).push(match);
  });

  byNode.forEach((list, node) => {
    list
      .sort((a, b) => b.dom.start - a.dom.start)
      .forEach(({ dom, audio }) => {
        const span = document.createElement("span");

        span.className = "speaking-word";
        span.dataset.start = audio.start;
        span.dataset.end = audio.end;
        span.textContent = node.data.slice(dom.start, dom.end);

        node.splitText(dom.end);
        const middle = node.splitText(dom.start);

        middle.parentNode.replaceChild(span, middle);
      });
  });
}
