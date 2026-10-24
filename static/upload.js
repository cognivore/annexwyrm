// annexwyrm/static/upload.js — progress for the two multipart forms
// (/upload and /items/<id>/edit).
//
// Progressive enhancement: without JavaScript the forms post as plain HTML
// and the browser's own busy indicator is the only feedback. With it, the
// same form is sent by XMLHttpRequest — the one browser API that reports
// upload progress — and the submit button gains a progress line. The two
// slow phases are shown separately: the bytes leaving the browser (bar,
// bytes, rate, time left), then the server's synchronous archive put
// (encrypt and copy to the remote; minutes for a large file) as an elapsed
// timer, since nothing else moves during it. On success the page follows
// the server's redirect to the item; on an error the server's message is
// shown and the form is re-enabled for another attempt. A second submit
// while one is in flight is ignored; leaving the page mid-upload asks first.
(function () {
  'use strict';

  function bytes(n) {
    if (n < 1000) return n + ' B';
    var units = ['kB', 'MB', 'GB', 'TB'], i = -1;
    do { n /= 1000; i++; } while (n >= 1000 && i < units.length - 1);
    return (n < 10 ? n.toFixed(1) : Math.round(n)) + ' ' + units[i];
  }

  function duration(s) {
    s = Math.round(s);
    if (s < 60) return s + ' s';
    var m = Math.floor(s / 60);
    if (m < 60) return m + ' min ' + (s % 60) + ' s';
    return Math.floor(m / 60) + ' h ' + (m % 60) + ' min';
  }

  function enhance(form) {
    var button = form.querySelector('button[type="submit"]');
    var file = form.querySelector('input[type="file"]');
    if (!button || !window.XMLHttpRequest || !window.FormData) return;

    var status = document.createElement('div');
    status.className = 'upload-status';
    status.hidden = true;
    var bar = document.createElement('progress');
    bar.max = 1;
    var text = document.createElement('p');
    text.className = 'upload-text';
    var abort = document.createElement('button');
    abort.type = 'button';
    abort.className = 'upload-abort';
    abort.textContent = 'cancel upload';
    status.appendChild(bar);
    status.appendChild(text);
    status.appendChild(abort);
    button.insertAdjacentElement('afterend', status);

    var xhr = null, timer = null;

    function say(msg, state) {
      text.textContent = msg;
      status.className = 'upload-status' + (state ? ' ' + state : '');
    }
    function finish(msg, state) {
      clearInterval(timer);
      xhr = null;
      button.disabled = false;
      form.classList.remove('uploading');
      say(msg, state);
    }
    function hasFile() { return !!(file && file.files && file.files.length); }

    form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      if (xhr) return;
      var started = Date.now(), total = 0, withFile = hasFile();
      xhr = new XMLHttpRequest();
      button.disabled = true;
      form.classList.add('uploading');
      status.hidden = false;
      bar.removeAttribute('value');
      say(withFile ? 'starting upload…' : 'saving…');

      xhr.upload.addEventListener('progress', function (e) {
        if (!e.lengthComputable) return;
        total = e.total;
        var elapsed = (Date.now() - started) / 1000;
        var rate = elapsed > 0.5 ? e.loaded / elapsed : 0;
        bar.value = e.loaded / e.total;
        var line = 'uploading ' + bytes(e.loaded) + ' of ' + bytes(e.total) +
          ' — ' + Math.floor(100 * e.loaded / e.total) + '%';
        if (rate > 0) line += ' · ' + bytes(rate) + '/s · about ' + duration((e.total - e.loaded) / rate) + ' left';
        say(line);
      });

      xhr.upload.addEventListener('load', function () {
        var sent = Date.now();
        bar.removeAttribute('value');
        var tick = function () {
          var s = duration((Date.now() - sent) / 1000);
          say(withFile
            ? 'uploaded ' + bytes(total) + ' · archiving on the server: encrypting and copying to your remote — ' +
              s + ' so far; a large file can take a few minutes'
            : 'saving on the server — ' + s);
        };
        tick();
        timer = setInterval(tick, 1000);
      });

      xhr.addEventListener('load', function () {
        if (xhr.status >= 200 && xhr.status < 400) {
          // The POST answered with a redirect to the item (303); the request
          // followed it, so responseURL is where the page should go.
          var dest = xhr.responseURL || form.action;
          clearInterval(timer);
          xhr = null;
          bar.value = 1;
          say('saved — opening the item…', 'done');
          window.location.assign(dest);
        } else {
          var type = xhr.getResponseHeader('Content-Type') || '';
          var why = type.indexOf('text/plain') === 0 && xhr.responseText.trim()
            ? xhr.responseText.trim()
            : (xhr.statusText || 'the server did not say why') + ' — reload the page; you may need to log in again';
          finish('failed (HTTP ' + xhr.status + '): ' + why, 'error');
        }
      });
      xhr.addEventListener('error', function () {
        finish('network error — the upload did not go through; check the connection and try again', 'error');
      });
      xhr.addEventListener('abort', function () { finish('upload cancelled', 'error'); });

      xhr.open(form.method || 'POST', form.action);
      xhr.send(new FormData(form));
    });

    abort.addEventListener('click', function () { if (xhr) xhr.abort(); });
    window.addEventListener('beforeunload', function (e) {
      if (xhr) { e.preventDefault(); e.returnValue = ''; }
    });
  }

  var forms = document.querySelectorAll('form[enctype="multipart/form-data"]');
  for (var i = 0; i < forms.length; i++) enhance(forms[i]);
})();
