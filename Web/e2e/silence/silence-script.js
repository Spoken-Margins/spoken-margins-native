// Injected, as a classic script at the top of <head>, into the test-only web builds (see silence-plugin.ts, #3375).
// Nothing a Playwright run plays or speaks may reach the Mac's speakers. This file never ships: a normal build does
// not contain it (Web/src/e2e-guard/silence-guard.test.ts builds one and checks).
//   1. Media elements keep a logical volume (what page code and tests read and write) and a real one held at 0.
//   2. speechSynthesis is replaced by a stub that fires the events a real engine does and speaks nothing.
//   3. Web Audio output is routed through a zero gain, so the destination stays silent and captures are untouched.
// It never sets `muted`: muted media relaxes a browser's autoplay rule, and a test about autoplay must not.
(function () {
  'use strict';
  if (window.__smSilent) return;
  var state = (window.__smSilent = { version: 1, spoken: [], speechCalls: [], realVolume: null });

  // ---- 1. Media elements -------------------------------------------------------------------------------------
  var proto = HTMLMediaElement.prototype;
  var volume = Object.getOwnPropertyDescriptor(proto, 'volume');
  var nativePlay = proto.play;
  var logical = new WeakMap();
  var silenced = new WeakSet();
  var realGet = function (el) { return volume.get.call(el); };
  var realSet = function (el, v) { volume.set.call(el, v); };
  state.realVolume = realGet;

  var logicalOf = function (el) { return logical.has(el) ? logical.get(el) : realGet(el); };

  Object.defineProperty(proto, 'volume', {
    configurable: true,
    enumerable: volume.enumerable,
    get: function () { return logicalOf(this); },
    set: function (value) {
      if (!silenced.has(this)) { // Not yet played: the real volume is the logical one, with the native checks.
        realSet(this, value);
        logical.set(this, realGet(this));
        return;
      }
      var v = Number(value);
      if (!isFinite(v)) throw new TypeError("Failed to set the 'volume' property on 'HTMLMediaElement': The provided double value is non-finite.");
      if (v < 0 || v > 1) throw new DOMException('The volume provided (' + v + ') is outside the range [0, 1].', 'IndexSizeError');
      var changed = v !== logicalOf(this);
      logical.set(this, v);
      var el = this;
      if (changed) queueMicrotask(function () { el.dispatchEvent(new Event('volumechange')); });
    },
  });

  // play() makes its permission decision at the logical, audible volume: a browser that lets volume 0 or muted
  // media start by itself must not let an audible one start here. The real volume goes back to 0 in the same task.
  proto.play = function () {
    var el = this;
    var l = logicalOf(el);
    if (silenced.has(el) && el.paused && realGet(el) !== l) realSet(el, l);
    try {
      return nativePlay.call(el);
    } finally {
      silenced.add(el);
      logical.set(el, l);
      if (realGet(el) !== 0) realSet(el, 0);
    }
  };

  // An element that starts by itself (the autoplay attribute) never passes through play(); hold it at 0 as soon as
  // its play event fires. The browser's own mute switch covers the first few milliseconds where it exists.
  document.addEventListener('play', function (event) {
    var el = event.target;
    if (!(el instanceof HTMLMediaElement) || silenced.has(el)) return;
    var l = logicalOf(el);
    silenced.add(el);
    logical.set(el, l);
    if (realGet(el) !== 0) realSet(el, 0);
  }, true);

  // ---- 2. Speech ---------------------------------------------------------------------------------------------
  var synth = window.speechSynthesis;
  if (synth && typeof SpeechSynthesisUtterance !== 'undefined') {
    var queue = [];
    var current = null;
    var paused = false;
    var timer = 0;
    var fire = function (utterance, type, extra) {
      var event;
      try {
        var Constructor = type === 'error' && typeof SpeechSynthesisErrorEvent !== 'undefined' ? SpeechSynthesisErrorEvent : SpeechSynthesisEvent;
        event = new Constructor(type, Object.assign({ utterance: utterance, charIndex: 0, elapsedTime: 0, name: '' }, extra || {}));
      } catch (e) {
        event = new Event(type);
        Object.assign(event, { utterance: utterance }, extra || {});
      }
      utterance.dispatchEvent(event);
    };
    // Long enough to see the episode turned down while a Margin is read, far inside speech.ts's 8 s + 120 ms/char watchdog.
    var lengthOf = function (u) { return Math.min(2000, 250 + 8 * (u.text || '').length); };
    var next = function () {
      if (current || paused || queue.length === 0) return;
      current = queue.shift();
      var u = current;
      timer = setTimeout(function () {
        if (current !== u) return;
        fire(u, 'start');
        timer = setTimeout(function () {
          if (current !== u) return;
          current = null;
          fire(u, 'end', { elapsedTime: lengthOf(u) });
          next();
        }, lengthOf(u));
      }, 20);
    };
    var define = function (name, descriptor) {
      Object.defineProperty(synth, name, Object.assign({ configurable: true, enumerable: true }, descriptor));
    };
    define('speak', { value: function (utterance) {
      state.speechCalls.push('speak');
      state.spoken.push(utterance.text);
      queue.push(utterance);
      next();
    } });
    define('cancel', { value: function () {
      state.speechCalls.push('cancel');
      var dropped = (current ? [current] : []).concat(queue);
      clearTimeout(timer);
      current = null;
      queue = [];
      paused = false;
      dropped.forEach(function (u) { setTimeout(function () { fire(u, 'error', { error: 'canceled' }); }, 0); });
    } });
    define('pause', { value: function () { state.speechCalls.push('pause'); if (current) { paused = true; clearTimeout(timer); } } });
    define('resume', { value: function () {
      state.speechCalls.push('resume');
      if (!paused) return;
      paused = false;
      var u = current;
      current = null;
      if (u) queue.unshift(u);
      next();
    } });
    define('speaking', { get: function () { return current !== null; } });
    define('pending', { get: function () { return queue.length > 0; } });
    define('paused', { get: function () { return paused; } });
  }

  // ---- 3. Web Audio ------------------------------------------------------------------------------------------
  var Destination = window.AudioDestinationNode;
  var Node = window.AudioNode;
  if (Destination && Node) {
    var nodeConnect = Node.prototype.connect;
    var nodeDisconnect = Node.prototype.disconnect;
    var sinks = new WeakMap();
    var live = function (node) { return !(typeof OfflineAudioContext !== 'undefined' && node.context instanceof OfflineAudioContext); };
    var sinkFor = function (node) {
      var context = node.context;
      var sink = sinks.get(context);
      if (!sink) {
        sink = context.createGain();
        sink.gain.value = 0;
        nodeConnect.call(sink, context.destination);
        sinks.set(context, sink);
      }
      return sink;
    };
    Node.prototype.connect = function (target) {
      if (target instanceof Destination && live(this)) {
        nodeConnect.call(this, sinkFor(this), arguments[1], arguments[2]);
        return target;
      }
      return nodeConnect.apply(this, arguments);
    };
    Node.prototype.disconnect = function (target) {
      if (target instanceof Destination && live(this)) {
        return nodeDisconnect.call(this, sinkFor(this), arguments[1], arguments[2]);
      }
      return nodeDisconnect.apply(this, arguments);
    };
  }
})();
