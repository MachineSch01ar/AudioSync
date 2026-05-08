import { apiInitializer } from "discourse/lib/api";

const AUDIO_EXTENSIONS = [".mp3", ".m4a", ".wav", ".ogg", ".aac"];
const JSON_EXTENSIONS = [".json"];
const SEEK_PLAY_TIMEOUT_MS = 750;
const METADATA_TIMEOUT_MS = 500;
const SEEK_SETTLE_TOLERANCE_SECONDS = 0.04;

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

      const alignmentDuration = getAlignmentDuration(audioWords);
      if (!alignmentDuration) {
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

      prepareAudioSource(audio);

      const clock = createClockMapper(audio, alignmentDuration);
      const syncOffset = getSyncOffset();
      let lastAlignmentTime = 0;
      let isLooping = false;
      let rafId = null;

      let player;

      const renderAt = (alignmentTime) => {
        const safeAlignmentTime = clampTime(alignmentTime, alignmentDuration);

        lastAlignmentTime = safeAlignmentTime;
        updateActiveSpans(spans, safeAlignmentTime);
        player?.update(safeAlignmentTime, audio.paused);

        return safeAlignmentTime;
      };

      const renderCurrentTime = () => {
        renderAt(clock.mediaToAlignmentTime(audio.currentTime) + syncOffset);
      };

      const cancelLoop = () => {
        isLooping = false;

        if (rafId) {
          cancelAnimationFrame(rafId);
          rafId = null;
        }
      };

      const renderLoop = () => {
        if (audio.paused) {
          isLooping = false;
          return;
        }

        renderCurrentTime();
        rafId = requestAnimationFrame(renderLoop);
      };

      const startLoop = () => {
        if (!isLooping) {
          isLooping = true;
          renderLoop();
        }
      };

      const seekToAlignment = async (
        alignmentTime,
        {
          play = false,
          highlightTime = alignmentTime,
          clickedWordStart = null,
          applySyncOffset = true,
        } = {}
      ) => {
        const safeAlignmentTime = clampTime(alignmentTime, alignmentDuration);
        const mediaAlignmentTime = clampTime(
          applySyncOffset ? safeAlignmentTime - syncOffset : safeAlignmentTime,
          alignmentDuration
        );

        renderAt(highlightTime);

        await waitForMetadata(audio, METADATA_TIMEOUT_MS);
        clock.captureMediaDuration();

        const targetMediaTime = clock.alignmentToMediaTime(mediaAlignmentTime);

        try {
          audio.currentTime = targetMediaTime;
        } catch (error) {
          debugWarn("AudioSync: audio seek failed:", error);
        }

        if (play) {
          await waitForSeekCompletion(
            audio,
            targetMediaTime,
            SEEK_PLAY_TIMEOUT_MS
          );

          if (clickedWordStart !== null) {
            debugLog("AudioSync: clicked word seek:", {
              clicked_word_start: clickedWordStart,
              requested_alignment_time: safeAlignmentTime,
              applied_sync_offset: applySyncOffset,
              requested_media_alignment_time: mediaAlignmentTime,
              requested_media_time: targetMediaTime,
              actual_media_time: audio.currentTime,
            });
          }

          await playAudio(audio);
          startLoop();
        }
      };

      const floatingEnabled = isFloatingPlayerEnabled();

      if (floatingEnabled) {
        element.classList.add("audio-sync-floating-context");
      }

      player = createAudioSyncPlayer({
        alignmentDuration,
        floatingEnabled,
        onTogglePlay: () => {
          if (audio.paused) {
            const restartFromBeginning =
              audio.ended || lastAlignmentTime >= alignmentDuration;
            const startTime = restartFromBeginning ? 0 : lastAlignmentTime;

            seekToAlignment(startTime, { play: true });
          } else {
            audio.pause();
          }
        },
        onSeekPreview: renderAt,
        onSeekCommit: (alignmentTime) => {
          seekToAlignment(alignmentTime, { play: !audio.paused });
        },
      });

      insertAfterAudio(audio, player.element, element);
      renderAt(0);

      audio.addEventListener("loadedmetadata", () => {
        clock.captureMediaDuration();
        renderCurrentTime();
      });
      audio.addEventListener("durationchange", () => {
        clock.captureMediaDuration();
      });
      audio.addEventListener("play", startLoop);
      audio.addEventListener("playing", startLoop);
      audio.addEventListener("timeupdate", () => {
        clock.captureMediaDuration();
        renderCurrentTime();
        startLoop();
      });

      audio.addEventListener("pause", () => {
        cancelLoop();
        renderCurrentTime();
      });

      audio.addEventListener("ended", () => {
        cancelLoop();
        renderAt(alignmentDuration);
      });

      element.addEventListener("click", (event) => {
        const target = event.target?.closest?.(".speaking-word");

        if (target) {
          event.preventDefault();
          event.stopPropagation();

          const start = parseFloat(target.dataset.start);

          if (!Number.isNaN(start)) {
            const preroll = getSeekPreroll();

            seekToAlignment(start - preroll, {
              play: true,
              highlightTime: start,
              clickedWordStart: start,
              applySyncOffset: false,
            });
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

function getSeekPreroll() {
  const preroll = Number(settings.seek_preroll_seconds ?? 0);

  return Number.isFinite(preroll) && preroll >= 0 ? preroll : 0;
}

function getSyncOffset() {
  const offset = Number(settings.highlight_offset_seconds ?? 0.08);

  return Number.isFinite(offset) ? offset : 0.08;
}

function isFloatingPlayerEnabled() {
  return (
    settings.floating_player_enabled === true ||
    settings.floating_player_enabled === "true"
  );
}

function prepareAudioSource(audio) {
  audio.controls = false;
  audio.preload = "metadata";
  audio.classList.add("audio-sync-source");
  audio.setAttribute("aria-hidden", "true");
  audio.tabIndex = -1;

  const onebox = audio.closest(".onebox, aside.onebox");
  if (onebox) {
    onebox.classList.add("audio-sync-source-wrapper");
  }

  if (audio.readyState === 0) {
    audio.load();
  }
}

function createAudioSyncPlayer({
  alignmentDuration,
  floatingEnabled = false,
  onTogglePlay,
  onSeekPreview,
  onSeekCommit,
}) {
  const element = document.createElement("div");
  element.className = "audio-sync-player";

  if (floatingEnabled) {
    element.classList.add("audio-sync-player--floating");
  }

  const button = document.createElement("button");
  button.type = "button";
  button.className = "audio-sync-play-toggle";

  const seek = document.createElement("input");
  seek.type = "range";
  seek.className = "audio-sync-seek";
  seek.min = "0";
  seek.max = String(alignmentDuration);
  seek.step = "0.01";
  seek.value = "0";
  seek.setAttribute("aria-label", "Seek narration");

  const time = document.createElement("span");
  time.className = "audio-sync-time";

  const durationLabel = formatTime(alignmentDuration);
  let isScrubbing = false;

  const setPlayingState = (isPlaying) => {
    button.textContent = isPlaying ? "Pause" : "Play";
    button.setAttribute(
      "aria-label",
      isPlaying ? "Pause narration" : "Play narration"
    );
  };

  const setTimeLabel = (alignmentTime) => {
    time.textContent = `${formatTime(alignmentTime)} / ${durationLabel}`;
  };

  button.addEventListener("click", onTogglePlay);

  seek.addEventListener("input", () => {
    isScrubbing = true;

    const alignmentTime = Number(seek.value);
    setTimeLabel(alignmentTime);
    onSeekPreview(alignmentTime);
  });

  seek.addEventListener("change", () => {
    isScrubbing = false;
    onSeekCommit(Number(seek.value));
  });

  seek.addEventListener("blur", () => {
    isScrubbing = false;
  });

  element.append(button, seek, time);
  setPlayingState(false);
  setTimeLabel(0);

  return {
    element,
    update(alignmentTime, isPaused) {
      const safeAlignmentTime = clampTime(alignmentTime, alignmentDuration);

      if (!isScrubbing) {
        seek.value = String(safeAlignmentTime);
      }

      setPlayingState(!isPaused);
      setTimeLabel(safeAlignmentTime);
    },
  };
}

function createClockMapper(audio, alignmentDuration) {
  let mediaDuration = null;

  const captureMediaDuration = () => {
    const duration = getFinitePositiveNumber(audio.duration);

    if (duration && duration !== mediaDuration) {
      mediaDuration = duration;
      debugLog(
        "AudioSync: media/alignment durations:",
        {
          mediaDuration,
          alignmentDuration,
          difference: mediaDuration - alignmentDuration,
        }
      );
    }

    return mediaDuration;
  };

  captureMediaDuration();

  return {
    captureMediaDuration,
    alignmentToMediaTime(alignmentTime) {
      const targetDuration = captureMediaDuration() || alignmentDuration;

      return clampTime(alignmentTime, targetDuration);
    },
    mediaToAlignmentTime(mediaTime) {
      captureMediaDuration();

      return clampTime(mediaTime, alignmentDuration);
    },
  };
}

function updateActiveSpans(spans, alignmentTime) {
  spans.forEach((span) => {
    if (alignmentTime >= span.start && alignmentTime < span.end) {
      span.el.classList.add("active");
    } else {
      span.el.classList.remove("active");
    }
  });
}

async function playAudio(audio) {
  try {
    const playPromise = audio.play();

    if (playPromise) {
      await playPromise;
    }
  } catch (error) {
    debugWarn("AudioSync: audio playback failed:", error);
  }
}

function waitForMetadata(audio, timeoutMs) {
  if (audio.readyState >= 1) {
    return Promise.resolve();
  }

  return waitForEvent(audio, "loadedmetadata", timeoutMs);
}

function waitForSeekCompletion(audio, targetTime, timeoutMs) {
  if (isNearTime(audio.currentTime, targetTime)) {
    return Promise.resolve();
  }

  return new Promise((resolve) => {
    let timeoutId;
    let intervalId;

    const done = () => {
      audio.removeEventListener("seeked", done);
      clearTimeout(timeoutId);
      clearInterval(intervalId);
      resolve();
    };

    const checkDone = () => {
      if (isNearTime(audio.currentTime, targetTime)) {
        done();
      }
    };

    audio.addEventListener("seeked", done, { once: true });
    intervalId = setInterval(checkDone, 25);
    timeoutId = setTimeout(done, timeoutMs);
    checkDone();
  });
}

function waitForEvent(target, eventName, timeoutMs) {
  return new Promise((resolve) => {
    let timeoutId;

    const done = () => {
      target.removeEventListener(eventName, done);

      if (timeoutId) {
        clearTimeout(timeoutId);
      }

      resolve();
    };

    target.addEventListener(eventName, done, { once: true });
    timeoutId = setTimeout(done, timeoutMs);
  });
}

function isNearTime(actualTime, targetTime) {
  return (
    Math.abs(Number(actualTime) - Number(targetTime)) <=
    SEEK_SETTLE_TOLERANCE_SECONDS
  );
}

function getAlignmentDuration(audioWords) {
  return audioWords.reduce((max, word) => {
    const end = getFinitePositiveNumber(word.end);

    return end && end > max ? end : max;
  }, 0);
}

function getFinitePositiveNumber(value) {
  const number = Number(value);

  return Number.isFinite(number) && number > 0 ? number : null;
}

function clampTime(time, duration) {
  const safeTime = Number.isFinite(Number(time)) ? Number(time) : 0;

  return Math.min(Math.max(safeTime, 0), duration);
}

function formatTime(seconds) {
  const totalSeconds = Math.max(0, Math.floor(Number(seconds) || 0));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const remainingSeconds = totalSeconds % 60;

  if (hours > 0) {
    return `${hours}:${padTime(minutes)}:${padTime(remainingSeconds)}`;
  }

  return `${padTime(minutes)}:${padTime(remainingSeconds)}`;
}

function padTime(value) {
  return String(value).padStart(2, "0");
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
  audio.className = "audio-sync-source-candidate";

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

function insertAfterAudio(audio, node, cookedElement) {
  const sourceNode = audio.closest(".onebox, aside.onebox") || audio;
  const anchor =
    findDirectChildContaining(cookedElement, sourceNode) || sourceNode;

  anchor.insertAdjacentElement("afterend", node);
}

function findDirectChildContaining(root, node) {
  if (!root || !node || !root.contains(node)) {
    return null;
  }

  let current = node;

  while (current?.parentElement && current.parentElement !== root) {
    current = current.parentElement;
  }

  return current?.parentElement === root ? current : null;
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
