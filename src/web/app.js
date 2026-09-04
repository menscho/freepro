"use strict";

/* freepro dashboard bindings. Vanilla JS, no dependencies, works offline.
 * Binds the index.html shell (nav [data-view-link], views section[data-view],
 * templates tpl-*) to the dashboard JSON API served by freepro-gui.
 * No query strings anywhere (the proxy strips them). All API-derived text
 * renders via textContent only, never innerHTML.
 */
(function () {
  var POLL_BASE_MS = 1500;
  var POLL_MAX_MS = 15000;
  var LOGS_LIMIT = 200;
  var MODELS_CAP = 200;
  var SPARK_KEEP = 40;
  var TOAST_MS = 4000;
  var RETRY_409 = 4;
  var RETRY_409_MS = 250;

  var state = {
    view: "dashboard",
    status: null,
    providers: [],
    modelsCache: [],
    modelsQuery: "",
    modelsFilter: "all",
    hidePaid: true,
    logLevel: "all",
    logFollow: true,
    logPaused: false,
    pollDelay: POLL_BASE_MS,
    pollTimer: null,
    spark: [],
    usageView: "timeline", usageRange: "7", usageModel: "", usageBusy: false,
    usage: { total_in: 0, total_out: 0, total_cached: 0, total_requests: 0, days: [] },
  };

  /* ---------- guarded DOM helpers ---------- */

  function byId(id) {
    var n = document.getElementById(id);
    return n || null;
  }

  function qs(sel, root) {
    try {
      return (root || document).querySelector(sel);
    } catch (e) {
      return null;
    }
  }

  function qsa(sel, root) {
    try {
      return Array.prototype.slice.call((root || document).querySelectorAll(sel));
    } catch (e) {
      return [];
    }
  }

  function el(tag, text, cls) {
    var n = document.createElement(tag || "div");
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = String(text);
    return n;
  }

  function clearNode(n) {
    if (!n) return;
    while (n.firstChild) n.removeChild(n.firstChild);
  }

  function maskKey(k) {
    var s = String(k === undefined || k === null ? "" : k);
    if (!s) return "<empty>";
    if (s.length <= 8) return "..." + s.slice(-4);
    return s.slice(0, 3) + "..." + s.slice(-2);
  }

  function setText(id, text) {
    var n = byId(id);
    if (n) n.textContent = text;
  }

  function setBind(bind, text, root) {
    var n = qs('[data-bind="' + bind + '"]', root);
    if (n) n.textContent = text;
  }

  /* ---------- toasts + modal ---------- */

  function toast(kind, msg) {
    var box = byId("toasts");
    if (!box && document.body) {
      box = el("div");
      box.id = "toasts";
      document.body.appendChild(box);
    }
    if (!box) return;
    var tpl = byId("tpl-toast");
    var item;
    if (tpl && tpl.content) {
      item = tpl.content.firstElementChild.cloneNode(true);
      var txt = qs('[data-bind="toast-text"]', item);
      if (txt) txt.textContent = String(msg);
      else item.textContent = String(msg);
      var dis = qs('[data-action="toast-dismiss"]', item);
      if (dis) dis.addEventListener("click", function () {
        if (item.parentNode === box) box.removeChild(item);
      });
    } else {
      item = el("div", msg, "toast");
    }
    item.classList.add("toast-" + (kind === "ok" || kind === "warn" || kind === "err" ? kind : "info"));
    box.appendChild(item);
    setTimeout(function () {
      if (item.parentNode === box) box.removeChild(item);
    }, TOAST_MS);
  }

  function confirmModal(title, body, confirmLabel, cb) {
    var root = byId("modal-root");
    var tpl = byId("tpl-modal");
    if (!root || !tpl || !tpl.content) {
      var ok = false;
      try {
        ok = window.confirm(String(title) + "\n" + String(body));
      } catch (e) {
        ok = true;
      }
      cb(ok);
      return;
    }
    clearNode(root);
    var node = tpl.content.firstElementChild.cloneNode(true);
    var t = qs('[data-bind="modal-title"]', node);
    var b = qs('[data-bind="modal-body"]', node);
    var yes = qs('[data-action="modal-confirm"]', node);
    var no = qs('[data-action="modal-cancel"]', node);
    if (t) t.textContent = String(title);
    if (b) b.textContent = String(body);
    if (yes) {
      yes.textContent = String(confirmLabel || "Confirm");
      yes.addEventListener("click", function () {
        clearNode(root);
        cb(true);
      });
    }
    if (no) no.addEventListener("click", function () {
      clearNode(root);
      cb(false);
    });
    root.appendChild(node);
    if (yes) yes.focus();
  }

  function formModal(title, fields, confirmLabel, cb) {
    var root = byId("modal-root");
    var tpl = byId("tpl-modal");
    if (!root || !tpl || !tpl.content) {
      cb(null);
      return;
    }
    clearNode(root);
    var node = tpl.content.firstElementChild.cloneNode(true);
    var t = qs('[data-bind="modal-title"]', node);
    var b = qs('[data-bind="modal-body"]', node);
    var yes = qs('[data-action="modal-confirm"]', node);
    var no = qs('[data-action="modal-cancel"]', node);
    if (t) t.textContent = String(title);
    var inputs = {};
    if (b) {
      clearNode(b);
      fields.forEach(function (f) {
        var wrap = el("div", null, "field");
        var lab = el("label", f.label);
        var inp = el("input");
        inp.type = "text";
        inp.value = f.value || "";
        inp.placeholder = f.placeholder || "";
        inp.autocomplete = "off";
        inp.spellcheck = false;
        wrap.appendChild(lab);
        wrap.appendChild(inp);
        b.appendChild(wrap);
        inputs[f.name] = inp;
      });
    }
    function close(val) {
      clearNode(root);
      cb(val);
    }
    if (yes) {
      yes.textContent = String(confirmLabel || "Save");
      yes.addEventListener("click", function () {
        var out = {};
        Object.keys(inputs).forEach(function (k) {
          out[k] = String(inputs[k].value || "").trim();
        });
        close(out);
      });
    }
    if (no) no.addEventListener("click", function () { close(null); });
    root.appendChild(node);
    var first = b ? b.querySelector("input") : null;
    if (first) first.focus();
  }

  /* ---------- fetch wrapper (409 auto-retry for mutations) ---------- */

  function apiFetch(path, opts) {
    opts = opts || {};
    var method = (opts.method || "GET").toUpperCase();
    var quiet = !!opts.quiet;
    var retries = opts.retry409 !== undefined ? opts.retry409 : (method === "GET" ? 0 : RETRY_409);
    var controller = null;
    var timer = null;
    try {
      if (typeof AbortController !== "undefined") controller = new AbortController();
    } catch (e) {
      controller = null;
    }
    if (controller) {
      timer = setTimeout(function () {
        try {
          controller.abort();
        } catch (e) { /* noop */ }
      }, 15000);
    }
    var init = { method: method, headers: { Accept: "application/json" } };
    if (controller) init.signal = controller.signal;
    if (opts.body !== undefined) {
      init.headers["Content-Type"] = "application/json";
      init.body = typeof opts.body === "string" ? opts.body : JSON.stringify(opts.body);
    }
    function attempt(left) {
      return fetch(path, init).then(
        function (res) {
          if (res.status === 409 && left > 0) {
            return new Promise(function (resolve) {
              setTimeout(function () {
                resolve(attempt(left - 1));
              }, RETRY_409_MS);
            });
          }
          if (timer) clearTimeout(timer);
          if (res.status === 409) {
            var busy = new Error("busy");
            busy.status = 409;
            if (!quiet) toast("warn", "Server busy. Retry shortly.");
            throw busy;
          }
          if (!res.ok) {
            var err = new Error("request failed: " + res.status);
            err.status = res.status;
            if (!quiet) toast("err", "Request failed (" + res.status + ").");
            throw err;
          }
          if (res.status === 204) return null;
          return res.text().then(function (tx) {
            if (!tx) return null;
            try {
              return JSON.parse(tx);
            } catch (e) {
              return tx;
            }
          });
        },
        function (netErr) {
          if (timer) clearTimeout(timer);
          var e2 = netErr && netErr.name === "AbortError" ? new Error("timeout") : netErr;
          if (!quiet) toast("err", "Network error.");
          throw e2;
        }
      );
    }
    return attempt(retries);
  }

  function apiGet(path, quiet) {
    return apiFetch(path, { method: "GET", quiet: quiet });
  }

  /* ---------- view router ---------- */

  var VIEW_META = {
    dashboard: "Overview",
    providers: "Providers",
    models: "Models",
    settings: "Settings",
    "quick-adds": "Quick adds",
  };

  function showView(name) {
    if (!VIEW_META[name]) name = "dashboard";
    state.view = name;
    qsa("section[data-view]").forEach(function (sec) {
      sec.hidden = sec.getAttribute("data-view") !== name;
    });
    qsa("[data-view-link]").forEach(function (b) {
      var on = b.getAttribute("data-view-link") === name;
      b.classList.toggle("is-active", on);
      b.setAttribute("aria-selected", on ? "true" : "false");
    });
    setText("view-title", VIEW_META[name]);
    try {
      var want = "#/" + name;
      if (window.location.hash !== want) window.location.hash = want;
    } catch (e) { /* noop */ }
    if (name === "dashboard") {
      refreshStatus(false).catch(function () { /* toasted */ });
      refreshUsage().catch(function () { /* quiet */ });
    } else if (name === "providers") {
      loadProviders();
    } else if (name === "models") {
      loadModels();
    } else if (name === "quick-adds") {
      loadQuickAdd();
    } else if (name === "settings") {
      loadSettings();
    }
  }

  var kimiToken = "";
  var kimiBusy = false;
  function kimiMessage(message, error) {
    var node = byId("kimi-add-status");
    if (!node) return;
    node.hidden = false;
    node.textContent = message;
    node.dataset.error = error ? "true" : "false";
  }
  function kimiRequest(body) {
    return fetch("/api/quick-adds/kimi", body ? {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body)
    } : {}).then(function (response) {
      return response.json().then(function (data) {
        if (!response.ok) throw new Error(typeof data.error === "string" ? data.error : (data.error && data.error.message) || "Could not update Kimi Code.");
        return data;
      });
    });
  }
  function loadQuickAdd() {
    if (kimiBusy) return;
    var button = byId("kimi-add-update");
    if (button) button.disabled = true;
    kimiRequest().then(function (data) {
      kimiToken = data.token;
      setText("kimi-config-path", data.path);
      if (button && !kimiBusy) button.disabled = false;
    }).catch(function (err) { kimiMessage(err.message, true); });
  }
  function applyQuickAdd() {
    if (kimiBusy || !kimiToken) return;
    kimiBusy = true;
    var button = byId("kimi-add-update");
    button.disabled = true;
    button.textContent = "Updating…";
    kimiMessage("Updating your Kimi Code configuration…", false);
    kimiRequest({ token: kimiToken }).then(function (result) {
      kimiMessage((result.changed ? "Saved · " + result.added + " added, " + result.updated + " updated." : "Already up to date.") + " Run /reload in Kimi Code.", false);
    }).catch(function (err) { kimiMessage(err.message, true); }).finally(function () {
      kimiBusy = false;
      button.disabled = false;
      button.textContent = "Add/Update";
    });
  }

  function initRouter() {
    qsa("[data-view-link]").forEach(function (b) {
      b.addEventListener("click", function () {
        showView(b.getAttribute("data-view-link"));
      });
    });
    window.addEventListener("hashchange", function () {
      var h = (window.location.hash || "").replace(/^#\/?/, "");
      if (h && h !== state.view) showView(h);
    });
    var start = (window.location.hash || "").replace(/^#\/?/, "") || "dashboard";
    showView(start);
  }

  /* ---------- status header, metrics, activity, spark ---------- */

  function statusPort() {
    var s = state.status || {};
    return s.port || 8080;
  }

  function baseUrl() {
    return "http://127.0.0.1:" + statusPort() + "/v1";
  }

  function renderStatus(s) {
    state.status = s || {};
    var running = !!state.status.running;
    var port = state.status.port || 8080;
    var pill = byId("proxy-pill");
    if (pill) {
      pill.textContent = running ? "Listening on :" + port : "Proxy stopped";
      pill.classList.toggle("on", running);
    }
    var dot = byId("status-dot");
    if (dot) dot.classList.toggle("on", running);
    setText("status-text", running ? "RUNNING" : "STOPPED");
    setText("listen-addr", "127.0.0.1:" + port);
    var portInput = byId("set-port");
    // Settings values are owned by the settings form, not status polling.
    // Rail power button is the single start/stop control.
    qsa('[data-action="shutdown"]').forEach(function (b) {
      b.title = running ? "Stop server" : "Start server";
      b.setAttribute("aria-label", b.title);
    });
    setBind("metric-providers", String(state.status.providers !== undefined ? state.status.providers : state.providers.length));
    setBind("metric-keys", String(state.status.total_keys !== undefined ? state.status.total_keys : 0));
    setBind("metric-healthy", String(state.status.healthy_keys !== undefined ? state.status.healthy_keys : 0));
    setBind("metric-inflight", String(state.status.in_flight !== undefined ? state.status.in_flight : 0));
    setBind("metric-served", String(state.status.total_served !== undefined ? state.status.total_served : 0));
    var avg = state.status.avg_latency_ms;
    setBind("metric-latency", avg === undefined || avg === null ? "n/a" : (avg >= 1000 ? (avg / 1000).toFixed(2) + " s" : Math.round(avg) + " ms"));
    setText("endpoint-url", baseUrl());
    var toggle = byId("proxy-toggle");
    if (toggle) { toggle.textContent = running ? "Stop proxy" : "Start proxy"; toggle.setAttribute("aria-pressed", String(running)); }
    var total = Number(state.status.total_keys) || 0;
    var healthy = Number(state.status.healthy_keys) || 0;
    var percent = total ? Math.round(100 * healthy / total) : 0;
    setText("health-percent", percent + "%");
    setText("healthy-count", healthy);
    setText("unhealthy-count", Math.max(0, total - healthy));
    var ring = byId("health-ring");
    if (ring) { ring.style.setProperty("--health", percent + "%"); ring.setAttribute("aria-label", healthy + " of " + total + " keys healthy"); }
    var now = Date.now(), served = Number(state.status.total_served) || 0;
    if (state.lastSample && now > state.lastSample.time) {
      var rate = Math.max(0, served - state.lastSample.served) / ((now - state.lastSample.time) / 1000);
      state.spark.push(rate);
      if (state.spark.length > SPARK_KEEP) state.spark.shift();
      setText("request-rate", rate.toFixed(1));
    }
    state.lastSample = { time: now, served: served };
    drawSpark();
    if (state.view === "dashboard") refreshUsage().catch(function () { /* quiet */ });
  }

  /* ---------- token usage (totals + daily chart) ---------- */

  function fmtTokens(n) {
    n = Number(n) || 0;
    if (n >= 1e9) return (Math.round(n / 1e8) / 10) + "B";
    if (n >= 1e6) return (Math.round(n / 1e5) / 10) + "M";
    if (n >= 1e3) return (Math.round(n / 1e2) / 10) + "K";
    return String(n);
  }

  var USAGE_COLORS = ["#86acff", "#b59aff", "#67d4ae", "#e6b972", "#dc8cba", "#71c2d9"];
  var UNKNOWN = "__unattributed__";
  function dayLabel(day) {
    return new Date(day * 86400000).toLocaleDateString(undefined, { month: "short", day: "numeric", timeZone: "UTC" });
  }
  function exact(n) { return (Number(n) || 0).toLocaleString(); }
  function normalizedDay(d) { return { day: Number(d.day), input: Number(d.input !== undefined ? d.input : d.in) || 0, output: Number(d.output !== undefined ? d.output : d.out) || 0, cached: Number(d.cached) || 0, requests: Number(d.requests) || 0 }; }
  function sumUsage(days) { return days.reduce(function(a,d) { a.input += d.input; a.output += d.output; a.cached += d.cached; a.requests += d.requests; return a; }, { input:0,output:0,cached:0,requests:0 }); }
  function totalTokens(row) { return row.input + row.output; }
  function modelLabel(name) { return name === UNKNOWN ? "Earlier usage · model unknown" : name === "__other_models__" ? "Other models" : name; }
  function shortModel(name) { return modelLabel(name).split("/").pop(); }
  function usageData() {
    var u = state.usage, today = Math.floor(Date.now()/86400000), all = state.usageRange === "all";
    var start = today - (all ? 29 : Number(state.usageRange)-1);
    var globalDays = (u.days || []).map(normalizedDay);
    var modelRows = (u.models || []).map(function(m) { return { model:m.model, input:Number(m.input)||0, output:Number(m.output)||0, cached:Number(m.cached)||0, requests:Number(m.requests)||0, days:(m.days||[]).map(normalizedDay) }; });
    var globalTotal = { input:Number(u.total_in)||0, output:Number(u.total_out)||0, cached:Number(u.total_cached)||0, requests:Number(u.total_requests)||0 };
    var tracked = sumUsage(modelRows);
    var unknown = { model:UNKNOWN, days:[] };
    ["input","output","cached","requests"].forEach(function(k) { unknown[k] = Math.max(0,globalTotal[k]-tracked[k]); });
    unknown.days = globalDays.map(function(d) {
      var r = Object.assign({},d);
      modelRows.forEach(function(m) { var md=m.days.find(function(x){return x.day===d.day;}); if(md) ["input","output","cached","requests"].forEach(function(k){r[k]=Math.max(0,r[k]-md[k]);}); });
      return r;
    });
    if (unknown.requests || totalTokens(unknown)) modelRows.push(unknown);
    var selected = modelRows.find(function(m){return m.model===state.usageModel;});
    var source = selected ? selected.days : globalDays;
    var days = [];
    for (var day=start;day<=today;day++) days.push(source.find(function(d){return d.day===day;}) || {day:day,input:0,output:0,cached:0,requests:0});
    var rows = modelRows.filter(function(m){return !selected || m.model===selected.model;}).map(function(m){return Object.assign({model:m.model},all ? {input:m.input,output:m.output,cached:m.cached,requests:m.requests} : sumUsage(m.days.filter(function(d){return d.day>=start && d.day<=today;})));}).filter(function(m){return m.requests || totalTokens(m);});
    rows.sort(function(a,b){return totalTokens(b)-totalTokens(a) || a.model.localeCompare(b.model);});
    return { days:days, rows:rows, total:all ? (selected || globalTotal) : sumUsage(days), all:all, models:modelRows, unknown:unknown };
  }
  function refreshUsage() {
    if(state.usageBusy) return Promise.resolve(state.usage);
    state.usageBusy=true;
    return apiGet("/api/usage",true).then(function(u) {
      state.usage=u || state.usage;
      renderUsage();
      return u;
    }).catch(function(e){setText("usage-history-note","Usage could not be refreshed. Showing the last available data.");throw e;}).finally(function(){state.usageBusy=false;});
  }
  function renderUsage() {
    var data=usageData(), today=Math.floor(Date.now()/86400000);
    var td=(state.usage.days||[]).map(normalizedDay).find(function(d){return d.day===today;}) || {input:0,output:0};
    setBind("metric-tokens",fmtTokens(totalTokens(td)));
    setText("tokens-today-detail",fmtTokens(td.input)+" input · "+fmtTokens(td.output)+" output");
    setText("overview-date",new Date().toLocaleDateString(undefined,{weekday:"long",month:"long",day:"numeric",timeZone:"UTC"})+" · UTC");
    var select=byId("usage-model");
    var signature=data.models.map(function(m){return m.model;}).sort().join("\n");
    if(select && signature!==state.modelOptionsSignature) {
      state.modelOptionsSignature=signature;clearNode(select);var opt=el("option","All models");opt.value="";select.appendChild(opt);
      data.models.slice().sort(function(a,b){return a.model.localeCompare(b.model);}).forEach(function(m){var o=el("option",modelLabel(m.model));o.value=m.model;select.appendChild(o);});
      select.value=state.usageModel;
      if(select.value!==state.usageModel){state.usageModel="";select.value="";data=usageData();}
    }
    setText("usage-total",fmtTokens(totalTokens(data.total)));
    setBind("usage-in",fmtTokens(data.total.input));setBind("usage-out",fmtTokens(data.total.output));setBind("usage-cached",fmtTokens(data.total.cached));setText("usage-requests",exact(data.total.requests));
    [["usage-total",totalTokens(data.total)],["usage-requests",data.total.requests]].forEach(function(v){var n=byId(v[0]);if(n)n.title=exact(v[1]);});
    ["in","out","cached"].forEach(function(k,i){var n=qs('[data-bind="usage-'+k+'"]');if(n)n.title=exact(data.total[["input","output","cached"][i]]);});
    setText("usage-period-label",data.all ? "All time · daily chart shows the last 30 days" : (state.usageRange==="1" ? "Today" : "Last "+state.usageRange+" days")+" · UTC");
    setText("usage-history-note",data.unknown.requests ? "Earlier totals are preserved; their model was not recorded." : "Provider-reported usage · 30 daily buckets · lifetime model totals");
    ["timeline","models","days"].forEach(function(v){var panel=byId("usage-"+v);if(panel)panel.hidden=state.usageView!==v;});
    qsa("[data-usage-view]").forEach(function(b){var on=b.dataset.usageView===state.usageView;b.classList.toggle("is-active",on);b.setAttribute("aria-pressed",String(on));});
    var key=JSON.stringify([data.rows,data.days,state.usageView,state.usageModel]);
    if(key!==state.usageRenderSignature){state.usageRenderSignature=key;renderUsageTables(data);renderDistribution(data);}
    drawUsageChart(data);
  }
  function emptyRow(body,cols,text) { var tr=el("tr"),td=el("td",text,"table-empty");td.colSpan=cols;tr.appendChild(td);body.appendChild(tr); }
  function renderUsageTables(data) {
    var body=byId("usage-model-rows");if(body){clearNode(body);
      if(!data.rows.length)emptyRow(body,7,"No model usage in this period.");
      data.rows.forEach(function(row,i){var tr=el("tr"),name=el("td"),button=el("button",modelLabel(row.model),"model-link");button.type="button";button.title="View daily usage for "+modelLabel(row.model);button.addEventListener("click",function(){selectUsageModel(row.model);});name.appendChild(button);tr.appendChild(name);
        var share=totalTokens(data.total)?totalTokens(row)/totalTokens(data.total)*100:0,cell=el("td"),track=el("span",null,"share-track"),bar=el("i");bar.style.width=share+"%";bar.style.background=USAGE_COLORS[i%USAGE_COLORS.length];track.appendChild(bar);cell.appendChild(track);cell.appendChild(document.createTextNode(share.toFixed(1)+"%"));tr.appendChild(cell);
        [row.input,row.output,row.cached,row.requests,totalTokens(row)].forEach(function(n){tr.appendChild(el("td",exact(n)));});body.appendChild(tr);
      });
    }
    body=byId("usage-day-rows");if(body){clearNode(body);data.days.slice().reverse().forEach(function(row){var tr=el("tr");tr.appendChild(el("td",new Date(row.day*86400000).toISOString().slice(0,10)));[row.input,row.output,row.cached,row.requests,totalTokens(row)].forEach(function(n){tr.appendChild(el("td",exact(n)));});body.appendChild(tr);});}
  }
  function selectUsageModel(model) {state.usageModel=model;state.usageView="timeline";var s=byId("usage-model");if(s)s.value=model;renderUsage();}
  function renderDistribution(data) {
    var donut=byId("model-donut"),legend=byId("model-legend");if(!donut||!legend)return;
    clearNode(legend);var rows=data.rows.filter(function(r){return totalTokens(r)>0;}), total=rows.reduce(function(n,r){return n+totalTokens(r);},0);
    setText("usage-model-count",rows.filter(function(r){return r.model!==UNKNOWN;}).length);
    if(!total){donut.style.background="#292930";legend.appendChild(el("span","No tokens in this period.","muted"));donut.setAttribute("aria-label","No tokens in this period");return;}
    var shown=rows.slice(0,4);if(rows.length>4)shown.push(Object.assign({model:"__remaining__"},sumUsage(rows.slice(4))));
    var position=0,stops=[];shown.forEach(function(row,i){var share=totalTokens(row)/total*100,color=row.model===UNKNOWN?"#73737f":USAGE_COLORS[i];stops.push(color+" "+position+"% "+(position+share)+"%");position+=share;
      var b=el("button"),dot=el("i",null,"dot"),label=row.model==="__remaining__"?"Other "+(rows.length-4)+" models":shortModel(row.model);dot.style.background=color;b.type="button";b.title=(row.model==="__remaining__"?label:modelLabel(row.model))+": "+exact(totalTokens(row))+" tokens";b.appendChild(dot);b.appendChild(el("span",label,"legend-name"));b.appendChild(el("b",share.toFixed(1)+"%"));b.addEventListener("click",function(){if(row.model==="__remaining__"){state.usageView="models";renderUsage();}else selectUsageModel(row.model);});legend.appendChild(b);
    });donut.style.background="conic-gradient("+stops.join(",")+")";donut.setAttribute("aria-label",rows.map(function(r){return modelLabel(r.model)+": "+exact(totalTokens(r))+" tokens";}).join("; "));
  }
  function fitCanvas(canvas,height) {
    var w=canvas.getBoundingClientRect().width;if(!w)return null;
    var dpr=window.devicePixelRatio||1;canvas.width=Math.round(w*dpr);canvas.height=Math.round(height*dpr);var ctx=canvas.getContext("2d");if(!ctx)return null;ctx.setTransform(dpr,0,0,dpr,0,0);return {ctx:ctx,w:w,h:height};
  }
  function drawUsageChart(data) {
    var cv=byId("usage-chart");if(!cv||state.usageView!=="timeline")return;data=data||usageData();var fit=fitCanvas(cv,Math.max(60,cv.parentElement.getBoundingClientRect().height));if(!fit)return;
    var ctx=fit.ctx,w=fit.w,h=fit.h,left=43,right=6,top=14,bottom=27,plot=h-top-bottom,days=data.days,max=Math.max(1,Math.max.apply(null,days.map(totalTokens))),step=(w-left-right)/days.length;
    max=Math.ceil(max/Math.pow(10,Math.floor(Math.log10(max))))*Math.pow(10,Math.floor(Math.log10(max)));
    ctx.font="10px 'Segoe UI',sans-serif";ctx.lineWidth=1;ctx.textAlign="right";
    for(var i=0;i<=4;i++){var y=top+plot*i/4;ctx.strokeStyle="#2b2b31";ctx.setLineDash([3,4]);ctx.beginPath();ctx.moveTo(left,y+.5);ctx.lineTo(w-right,y+.5);ctx.stroke();ctx.fillStyle="#81818d";ctx.fillText(fmtTokens(max*(4-i)/4),left-9,y+3);}
    ctx.setLineDash([]);state.usageBars=[];
    days.forEach(function(d,i){var width=Math.max(2,Math.min(38,step*.62)),x=left+i*step+(step-width)/2,hi=d.input/max*plot,ho=d.output/max*plot;
      ctx.fillStyle="#86acff";if(hi>0)ctx.fillRect(x,top+plot-hi,width,hi);ctx.fillStyle="#b59aff";if(ho>0)ctx.fillRect(x,top+plot-hi-ho,width,ho);
      if(!hi&&!ho){ctx.fillStyle="#3d3d46";ctx.fillRect(x,top+plot-2,width,2);}
      state.usageBars.push({x:left+i*step,width:step,day:d});
      var skip=days.length<=7?1:Math.ceil(days.length/Math.max(2,Math.floor(w/75)));
      if(i%skip===0||i===days.length-1){ctx.textAlign="center";ctx.fillStyle="#81818d";ctx.fillText(dayLabel(d.day),left+(i+.5)*step,h-6);}
    });
    if(!days.some(function(d){return totalTokens(d)>0;})){ctx.textAlign="center";ctx.fillStyle="#a0a0ab";ctx.fillText("No token usage in this period",left+(w-left)/2,top+plot/2);}
    cv.setAttribute("aria-label","Daily input and output tokens. "+exact(totalTokens(sumUsage(days)))+" total. Exact values are available in Daily log.");
  }
  function initUsage() {
    qsa("[data-usage-view]").forEach(function(b){b.addEventListener("click",function(){state.usageView=b.dataset.usageView;renderUsage();});});
    byId("usage-range").addEventListener("change",function(e){state.usageRange=e.target.value;renderUsage();});
    byId("usage-model").addEventListener("change",function(e){state.usageModel=e.target.value;renderUsage();});
    byId("usage-export").addEventListener("click",function(){
      var data=usageData(),byModel=state.usageView==="models",rows=byModel?data.rows:data.days;
      function csv(v){var s=String(v);if(/^[=+@-]/.test(s))s="'"+s;return '"'+s.replace(/"/g,'""')+'"';}
      var lines=[[byModel?"Model":"Date (UTC)","Input tokens","Output tokens","Cached input tokens","Requests","Total tokens"]];
      rows.forEach(function(r){lines.push([byModel?modelLabel(r.model):new Date(r.day*86400000).toISOString().slice(0,10),r.input,r.output,r.cached,r.requests,totalTokens(r)]);});
      var url=URL.createObjectURL(new Blob(["\ufeff"+lines.map(function(row){return row.map(csv).join(",");}).join("\r\n")],{type:"text/csv;charset=utf-8"}));var a=el("a");a.href=url;a.download="freepro-"+(byModel?"models":"daily")+"-"+new Date().toISOString().slice(0,10)+".csv";document.body.appendChild(a);a.click();a.remove();setTimeout(function(){URL.revokeObjectURL(url);},1000);
    });
    var cv=byId("usage-chart"),tip=byId("usage-tooltip");
    cv.addEventListener("pointermove",function(e){var rect=cv.getBoundingClientRect(),x=e.clientX-rect.left,b=(state.usageBars||[]).find(function(b){return x>=b.x&&x<b.x+b.width;});if(!b){tip.hidden=true;return;}var d=b.day;tip.textContent=dayLabel(d.day)+" · UTC\nInput  "+exact(d.input)+"\nOutput  "+exact(d.output)+"\nCached  "+exact(d.cached)+"\nRequests  "+exact(d.requests);tip.hidden=false;tip.style.left=Math.max(5,Math.min(x+12,rect.width-tip.offsetWidth-6))+"px";});
    cv.addEventListener("pointerleave",function(){tip.hidden=true;});
    var resize=function(){drawUsageChart();drawSpark();};if(window.ResizeObserver)new ResizeObserver(resize).observe(qs(".usage-panel"));else window.addEventListener("resize",resize);
  }

  function drawSpark() {
    var cv = byId("spark");
    if (!cv || !cv.getContext) return;
    var fit = fitCanvas(cv, cv.getBoundingClientRect().height || 48);
    if (!fit) return;
    var ctx = fit.ctx, w = fit.w, h = fit.h, pad = 4;
    var data = state.spark, max = Math.max(1, Math.ceil(Math.max.apply(null, data)));
    ctx.clearRect(0, 0, w, h);
    ctx.font = "10px system-ui";
    for (var row = 0; row < 2; row++) {
      var y = 8 + row * (h - 20);
      ctx.strokeStyle = "#2b2b31"; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(pad, y); ctx.lineTo(w, y); ctx.stroke();

    }
    if (data.length < 2) { ctx.fillStyle = "#a0a0ab"; ctx.fillText("Collecting live request data…", pad + 14, h / 2); return; }
    var points = data.map(function(v, i) { return [pad + i * (w-pad) / (SPARK_KEEP-1), h-12-v/max*(h-20)]; });
    ctx.beginPath(); ctx.moveTo(points[0][0], h-12);
    points.forEach(function(p) { ctx.lineTo(p[0],p[1]); });
    ctx.lineTo(points[points.length-1][0], h-12); ctx.closePath();
    var fill = ctx.createLinearGradient(0, 0, 0, h); fill.addColorStop(0, "#86acff25"); fill.addColorStop(1, "#86acff00");
    ctx.fillStyle = fill; ctx.fill(); ctx.beginPath();
    points.forEach(function(p, i) { if(i) ctx.lineTo(p[0],p[1]); else ctx.moveTo(p[0],p[1]); });
    ctx.strokeStyle = "#86acff"; ctx.lineWidth = 2.5; ctx.stroke();
    cv.setAttribute("aria-label", "Request rate: " + data[data.length-1].toFixed(1) + " requests per second; " + data.length + " samples");
  }

  function fmtTime(ms) {
    try {
      var d = new Date(Number(ms));
      if (isNaN(d.getTime())) return "";
      function p(x) {
        return (x < 10 ? "0" : "") + x;
      }
      return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
    } catch (e) {
      return "";
    }
  }

  function normLevel(lv) {
    var s = String(lv === undefined || lv === null ? "" : lv).toLowerCase();
    if (s === "req") return "request";
    if (s === "err") return "error";
    return s;
  }

  function logLineText(e) {
    var msg = e.msg !== undefined ? e.msg : (e.message !== undefined ? e.message : "");
    var ts = e.timestamp_ms !== undefined ? fmtTime(e.timestamp_ms) : "";
    var lv = e.level !== undefined ? String(e.level) : "";
    var pre = "";
    if (ts) pre += ts + " ";
    if (lv) pre += "[" + lv + "] ";
    return pre + String(msg);
  }

  function renderActivity(entries) {
    var box = byId("activity-list");
    if (!box) return;
    clearNode(box);
    var list = Array.isArray(entries) ? entries : (entries && Array.isArray(entries.logs) ? entries.logs : []);
    list.slice(-8).reverse().forEach(function (e) {
      box.appendChild(el("li", logLineText(e)));
    });
    if (!list.length) box.appendChild(el("li", "No activity yet."));
  }

  function refreshStatus(loud) {
    return apiGet("/api/status", !loud).then(function (s) {
      renderStatus(s || {});
      state.pollDelay = POLL_BASE_MS;
      return s;
    });
  }

  /* ---------- server controls ---------- */

  function toggleServer() {
    var running = !!(state.status && state.status.running);
    apiFetch("/api/server", { method: "POST", body: { action: running ? "stop" : "start" } }).then(function () {
      toast("ok", running ? "Server stopped." : "Server started.");
      return refreshStatus(false);
    }).catch(function () { /* toasted already */ });
  }

  function applyPort() {
    var input = byId("set-port");
    if (!input) return;
    var port = Math.floor(Number(input.value));
    if (!isFinite(port) || port < 1 || port > 65535) {
      toast("warn", "Port must be 1-65535.");
      return;
    }
    apiFetch("/api/settings", { method: "PUT", body: { port: port } }).then(function () {
      toast("ok", "Port set to " + port + ".");
      return refreshStatus(false);
    }).catch(function () { /* toasted already */ });
  }

  function copyUrl() {
    var u = baseUrl();
    function done() {
      toast("ok", "Copied " + u);
    }
    function fallback() {
      try {
        var ta = document.createElement("textarea");
        ta.value = u;
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        document.execCommand("copy");
        document.body.removeChild(ta);
        done();
      } catch (e) {
        toast("err", "Copy failed.");
      }
    }
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(u).then(done, fallback);
      else fallback();
    } catch (e) {
      fallback();
    }
  }

  function shutdownServer() {
    var running = !!(state.status && state.status.running);
    if (running) {
      confirmModal("Stop server", "Stop the proxy server? The process keeps running until quit.", "Stop", function (ok) {
        if (!ok) return;
        apiFetch("/api/server", { method: "POST", body: { action: "stop" } }).then(function () {
          toast("ok", "Server stopped.");
          return refreshStatus(false);
        }).catch(function () { /* toasted already */ });
      });
    } else {
      toggleServer();
    }
  }

  function pingAll() {
    var pros = state.providers;
    if (!pros.length) {
      toast("warn", "No providers yet.");
      return;
    }
    var jobs = [];
    pros.forEach(function (p, i) {
      var keys = Array.isArray(p.keys) ? p.keys : [];
      var ki = -1;
      for (var k = 0; k < keys.length; k++) {
        if (keys[k] && keys[k].enabled !== false && keys[k].state === "Active") {
          ki = k;
          break;
        }
      }
      if (ki < 0) return;
      jobs.push(apiFetch("/api/providers/" + i + "/ping/" + ki, { method: "POST", body: {}, quiet: true }).then(
        function (r) {
          return { ok: !!(r && r.ok), name: p.display_name || ("provider " + i) };
        },
        function () {
          return apiFetch("/api/providers/" + i + "/keys/" + ki + "/ping", { method: "POST", body: {}, quiet: true }).then(
            function (r) {
              return { ok: !!(r && r.ok), name: p.display_name || ("provider " + i) };
            },
            function () {
              return { ok: false, name: p.display_name || ("provider " + i) };
            }
          );
        }
      ));
    });
    if (!jobs.length) {
      toast("warn", "No healthy keys to ping.");
      return;
    }
    Promise.all(jobs).then(function (rs) {
      var good = rs.filter(function (r) { return r.ok; }).length;
      toast(good === rs.length ? "ok" : "warn", "Ping: " + good + " of " + rs.length + " healthy.");
      loadProviders();
    });
  }

  /* ---------- providers ---------- */

  function providerHealth(p) {
    var keys = Array.isArray(p.keys) ? p.keys : [];
    var h = keys.filter(function (k) {
      return k && k.enabled !== false && k.state === "Active";
    }).length;
    return { healthy: h, total: keys.length, pct: keys.length ? Math.round((h / keys.length) * 100) : 0 };
  }

  function badgeName(k) {
    if (!k || k.enabled === false) return "Disabled";
    if (!k.state) return "Healthy";
    if (k.state === "Active") return "Healthy";
    if (k.state === "CoolingDown") return "Cooldown";
    return "Dead";
  }

  function setKeyEnabled(pi, ki, enabled) {
    apiFetch("/api/providers/" + pi + "/keys/" + ki, { method: "PATCH", body: { enabled: !!enabled } }).then(function () {
      toast("ok", enabled ? "Key enabled." : "Key disabled.");
      loadProviders();
    }).catch(function () { /* toasted already */ });
  }

  function deleteKey(pi, ki) {
    confirmModal("Delete key", "Delete key #" + (ki + 1) + "?", "Delete", function (ok) {
      if (!ok) return;
      apiFetch("/api/providers/" + pi + "/keys/" + ki, { method: "DELETE" }).then(function () {
        toast("ok", "Key deleted.");
        loadProviders();
      }).catch(function () { /* toasted already */ });
    });
  }

  function pingKey(pi, ki) {
    apiFetch("/api/providers/" + pi + "/ping/" + ki, { method: "POST", body: {} }).then(function (r) {
      toast(r && r.ok ? "ok" : "warn", "Ping status " + (r && r.status !== undefined ? r.status : "?") + ".");
      loadProviders();
    }).catch(function (e) {
      if (e && (e.status === 404 || e.status === 405)) {
        apiFetch("/api/providers/" + pi + "/keys/" + ki + "/ping", { method: "POST", body: {} }).then(function (r) {
          toast(r && r.ok ? "ok" : "warn", "Ping status " + (r && r.status !== undefined ? r.status : "?") + ".");
          loadProviders();
        }).catch(function () { /* toasted already */ });
      }
    });
  }

  function buildKeyRow(pi, k, ki) {
    var tpl = byId("tpl-key-row");
    var li;
    if (tpl && tpl.content) {
      li = tpl.content.firstElementChild.cloneNode(true);
    } else {
      li = el("li", null, "key-row");
      li.appendChild(el("span", "", "mono"));
      li.appendChild(el("span", "", "badge"));
      var acts = el("span", null, "key-actions");
      ["Ping", "On", "Copy", "Del"].forEach(function (lbl) {
        acts.appendChild(el("button", lbl, "btn small"));
      });
      li.appendChild(acts);
    }
    var mask = qs('[data-bind="key-mask"]', li) || li.firstChild;
    if (mask) mask.textContent = maskKey(k && k.id !== undefined ? k.id : "");
    var state = qs('[data-bind="key-state"]', li);
    var badgeNameStr = badgeName(k);
    if (state) {
      state.textContent = badgeNameStr;
      state.className = "badge badge-" + badgeNameStr.toLowerCase();
    }
    var tgl = qs('[data-action="key-toggle"]', li);
    if (tgl) {
      var on = !k || k.enabled !== false;
      tgl.textContent = on ? "On" : "Off";
      tgl.setAttribute("aria-pressed", on ? "true" : "false");
      tgl.addEventListener("click", function () {
        setKeyEnabled(pi, ki, !on);
      });
    }
    var ping = qs('[data-action="key-ping"]', li);
    if (ping) ping.addEventListener("click", function () {
      pingKey(pi, ki);
    });
    var cp = qs('[data-action="key-copy"]', li);
    if (cp) cp.addEventListener("click", function () {
      var v = mask ? mask.textContent : "";
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(v).then(function () {
          toast("ok", "Key id copied.");
        });
        else toast("info", v);
      } catch (e) {
        toast("info", v);
      }
    });
    var del = qs('[data-action="key-remove"]', li);
    if (del) del.addEventListener("click", function () {
      deleteKey(pi, ki);
    });
    return li;
  }

  function renderHeaderRow(pi, tbody, h, hi) {
    var tr = el("tr");
    tr.appendChild(el("td", h.key || ""));
    var vtd = el("td");
    var vspan = el("span", h.value || "");
    vtd.appendChild(vspan);
    var td = el("td");
    var edit = el("button", "Edit", "btn small");
    edit.type = "button";
    edit.addEventListener("click", function () {
      clearNode(vtd);
      var inp = el("input");
      inp.type = "text";
      inp.value = h.value || "";
      inp.setAttribute("aria-label", "Header value");
      var save = el("button", "Save", "btn small primary");
      save.type = "button";
      save.addEventListener("click", function () {
        apiFetch("/api/providers/" + pi + "/headers/" + hi, {
          method: "PUT",
          body: { key: h.key, value: inp.value },
        }).then(function () {
          toast("ok", "Header saved.");
          loadProviders();
        }).catch(function () { /* toasted already */ });
      });
      vtd.appendChild(inp);
      vtd.appendChild(save);
      inp.focus();
    });
    var del = el("button", "Del", "btn small danger");
    del.type = "button";
    del.addEventListener("click", function () {
      apiFetch("/api/providers/" + pi + "/headers/" + hi, { method: "DELETE" }).then(function () {
        toast("ok", "Header deleted.");
        loadProviders();
      }).catch(function () { /* toasted already */ });
    });
    td.appendChild(edit);
    td.appendChild(del);
    tr.appendChild(vtd);
    tr.appendChild(td);
    tbody.appendChild(tr);
  }

  // Provider logo tile: a single letter mark keyed off the display name.
  function providerLogo(p) {
    var name = String(p.display_name || p.prefix || "?").trim();
    var ch = name.charAt(0).toUpperCase();
    // Deterministic hue per provider keeps tiles distinct but monochrome.
    var hues = [210, 160, 25, 280, 340, 80, 130, 240];
    var h = 0;
    for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
    var hue = hues[h % hues.length];
    return { ch: ch, hue: hue };
  }

  function buildProviderCard(p, pi) {
    var tpl = byId("tpl-provider-card");
    var card;
    if (tpl && tpl.content) {
      card = tpl.content.firstElementChild.cloneNode(true);
    } else {
      card = el("article", null, "card");
    }
    card.setAttribute("data-provider", String(pi));
    qsa("input[id]", card).forEach(function(input) {
      var old = input.id;
      input.id = old + "-" + pi;
      qsa("label", card).forEach(function(label) { if (label.htmlFor === old) label.htmlFor = input.id; });
    });
    var logo = providerLogo(p);
    var logoN = qs('[data-bind="provider-logo"]', card);
    if (logoN) {
      logoN.textContent = logo.ch;
      logoN.style.color = "hsl(" + logo.hue + ", 55%, 70%)";
    }
    var nameN = qs('[data-bind="provider-name"]', card);
    if (nameN && nameN.tagName === "INPUT") {
      nameN.value = String(p.display_name || "");
      // Auto-save on Enter or blur; no separate Save button.
      nameN.addEventListener("keydown", function (ev) {
        if (ev.key === "Enter") {
          ev.preventDefault();
          nameN.blur();
        }
      });
      nameN.addEventListener("change", function () {
        var nn = String(nameN.value || "").trim();
        if (!nn) {
          toast("warn", "Display name required.");
          nameN.value = String(p.display_name || "");
          return;
        }
        if (nn === String(p.display_name || "")) return;
        apiFetch("/api/providers/" + pi, { method: "PUT", body: { display_name: nn } }).then(function () {
          p.display_name = nn;
          toast("ok", "Renamed to " + nn + ".");
        }).catch(function () {
          nameN.value = String(p.display_name || "");
        });
      });
    }
    var preN = qs('[data-bind="provider-prefix"]', card);
    if (preN) preN.textContent = String(p.prefix || "");
    var urlN = qs('[data-bind="provider-url"]', card);
    if (urlN) {
      urlN.textContent = String(p.base_url || "");
      urlN.title = String(p.base_url || "");
    }
    var noteN = qs('[data-bind="provider-note"]', card);
    if (noteN) noteN.textContent = String(p.note || "");
    var siteN = qs('[data-bind="provider-site-link"]', card);
    if (siteN) {
      var site = String(p.site_url || "");
      if (site) {
        siteN.href = site;
        siteN.title = site;
      } else {
        siteN.removeAttribute("href");
      }
    }
    var proxyT = qs('[data-bind="provider-proxy-toggle"]', card);
    if (proxyT) {
      proxyT.checked = !!p.use_free_proxy;
      proxyT.addEventListener("change", function () {
        var on = !!proxyT.checked;
        apiFetch("/api/providers/" + pi, { method: "PUT", body: { use_free_proxy: on } }).then(function () {
          p.use_free_proxy = on;
          if (on) toast("warn", "Free proxies on for " + (p.display_name || "provider") + ": API key ban risk.");
          else toast("ok", "Free proxies off.");
        }).catch(function () {
          proxyT.checked = !on;
        });
      });
    }
    var st = providerHealth(p);
    var ht = qs('[data-bind="provider-health-text"]', card);
    if (ht) ht.textContent = st.healthy + "/" + st.total + " keys";
    var hb = qs('[data-bind="provider-health-bar"]', card);
    if (hb) hb.style.width = st.pct + "%";
    var list = qs('[data-bind="provider-keys"]', card);
    if (list) {
      clearNode(list);
      var keys = Array.isArray(p.keys) ? p.keys : [];
      if (!keys.length) list.appendChild(el("li", "No keys yet. Paste one below."));
      keys.forEach(function (k, ki) {
        list.appendChild(buildKeyRow(pi, k, ki));
      });
    }
    var addInput = qs('[data-bind="provider-key-input"]', card);
    var addBtn = qs('[data-action="provider-key-add"]', card);
    if (addBtn) addBtn.addEventListener("click", function () {
      var v = addInput ? String(addInput.value || "").trim() : "";
      if (!v) {
        toast("warn", "Key is blank.");
        return;
      }
      apiFetch("/api/providers/" + pi + "/keys", { method: "POST", body: { key: v } }).then(function () {
        toast("ok", "Key added.");
        loadProviders();
      }).catch(function () { /* toasted already */ });
    });
    if (addInput) addInput.addEventListener("keydown", function (ev) {
      if (ev.key === "Enter") {
        ev.preventDefault();
        if (addBtn) addBtn.click();
      }
    });
    var hbody = qs('[data-bind="headers-body"]', card);
    var hs = Array.isArray(p.headers) ? p.headers : [];
    var hcount = qs('[data-bind="header-count"]', card);
    if (hcount) hcount.textContent = String(hs.length);
    if (hbody) {
      clearNode(hbody);
      if (!hs.length) {
        var tr0 = el("tr");
        var td0 = el("td", "No custom headers.");
        td0.colSpan = 3;
        tr0.appendChild(td0);
        hbody.appendChild(tr0);
      }
      hs.forEach(function (h, hi) {
        renderHeaderRow(pi, hbody, h, hi);
      });
    }
    var hnInput = qs('[data-bind="header-name-input"]', card);
    var hvInput = qs('[data-bind="header-value-input"]', card);
    var hadd = qs('[data-action="header-add"]', card);
    if (hadd) hadd.addEventListener("click", function () {
      var n = hnInput ? String(hnInput.value || "").trim() : "";
      var v = hvInput ? String(hvInput.value || "") : "";
      if (!n) {
        toast("warn", "Header name required.");
        return;
      }
      apiFetch("/api/providers/" + pi + "/headers", { method: "POST", body: { key: n, value: v } }).then(function () {
        toast("ok", "Header added.");
        loadProviders();
      }).catch(function () { /* toasted already */ });
    });
    var note = qs('[data-bind="provider-models-note"]', card);
    if (note) {
      var mc = Array.isArray(p.models) ? p.models.length : 0;
      note.textContent = mc > 0 ? mc + " models" : "";
    }
    var rem = qs('[data-action="provider-remove"]', card);
    if (rem) rem.addEventListener("click", function () {
      confirmModal("Remove provider", "Remove " + (p.display_name || ("provider " + pi)) + "?", "Remove", function (ok) {
        if (!ok) return;
        apiFetch("/api/providers/" + pi, { method: "DELETE" }).then(function () {
          toast("ok", "Provider removed.");
          loadProviders();
        }).catch(function () { /* toasted already */ });
      });
    });
    return card;
  }

  function renderProviders() {
    var grid = byId("provider-grid");
    if (!grid) return;
    clearNode(grid);
    var q = "";
    var search = byId("provider-search");
    if (search) q = String(search.value || "").toLowerCase().trim();
    var shown = 0;
    state.providers.forEach(function (p, pi) {
      var hay = String((p.display_name || "") + " " + (p.prefix || "") + " " + (p.base_url || "")).toLowerCase();
      if (q && hay.indexOf(q) < 0) return;
      grid.appendChild(buildProviderCard(p, pi));
      shown++;
    });
    if (!state.providers.length) grid.appendChild(el("p", "No providers yet."));
    else if (!shown) grid.appendChild(el("p", "No providers match."));
  }

  function loadProviders() {
    return apiGet("/api/providers", state.view !== "providers").then(function (data) {
      var list = Array.isArray(data) ? data : (data && Array.isArray(data.providers) ? data.providers : []);
      state.providers = list;
      if (state.view === "providers") renderProviders();
    }).catch(function () {
      if (state.view === "providers") toast("err", "Providers failed to load.");
    });
  }

  function addProvider() {
    formModal("Add provider", [
      { name: "display_name", label: "Display name", placeholder: "My gateway" },
      { name: "base_url", label: "Base URL", placeholder: "https://example.com/v1" },
      { name: "prefix", label: "Prefix", placeholder: "my/" },
      { name: "description", label: "Description", placeholder: "Optional" },
    ], "Add", function (vals) {
      if (!vals) return;
      if (!vals.display_name) {
        toast("warn", "Display name required.");
        return;
      }
      if (!vals.base_url) {
        toast("warn", "Base URL required.");
        return;
      }
      if (!vals.prefix) {
        toast("warn", "Prefix required.");
        return;
      }
      var body = {
        display_name: vals.display_name,
        base_url: vals.base_url,
        prefix: vals.prefix,
        description: vals.description || "",
      };
      apiFetch("/api/providers", { method: "POST", body: body }).then(function () {
        toast("ok", "Provider added.");
        loadProviders();
      }).catch(function () { /* toasted already */ });
    });
  }

  function bulkImport() {
    var ta = byId("bulk-textarea");
    var raw = ta ? String(ta.value || "") : "";
    var lines = raw.split("\n").map(function (s) { return s.trim(); }).filter(function (s) { return s.length > 0; });
    if (!lines.length) {
      toast("warn", "Nothing to import.");
      return;
    }
    var pros = state.providers;
    if (!pros.length) {
      toast("warn", "Add a provider first.");
      return;
    }
    function findProvider(token) {
      var t = String(token).replace(/\/$/, "").toLowerCase();
      for (var i = 0; i < pros.length; i++) {
        var pre = String(pros[i].prefix || "").replace(/\/$/, "").toLowerCase();
        if (pre && (pre === t || pros[i].prefix.toLowerCase() === String(token).toLowerCase())) return i;
      }
      return -1;
    }
    var buckets = {};
    var stray = [];
    lines.forEach(function (line) {
      var parts = line.split(/\s*\|\s*|\s+/).filter(function (s) { return s.length > 0; });
      if (parts.length >= 2 && findProvider(parts[0]) >= 0) {
        var pi = findProvider(parts[0]);
        (buckets[pi] = buckets[pi] || []).push(parts.slice(1).join(" "));
      } else if (pros.length === 1) {
        (buckets[0] = buckets[0] || []).push(line);
      } else {
        stray.push(line);
      }
    });
    if (stray.length) {
      toast("warn", stray.length + " lines need a provider prefix.");
      return;
    }
    var ids = Object.keys(buckets);
    var chain = Promise.resolve();
    var added = 0;
    ids.forEach(function (id) {
      chain = chain.then(function () {
        return apiFetch("/api/providers/" + id + "/keys", { method: "POST", body: { keys: buckets[id] } }).then(function (r) {
          added += (r && r.added !== undefined) ? r.added : buckets[id].length;
        });
      });
    });
    chain.then(function () {
      toast("ok", "Imported " + added + " keys.");
      if (ta) ta.value = "";
      loadProviders();
    }).catch(function () { /* toasted already */ });
  }

  /* ---------- models ---------- */

  // Flat view-model built from GET /api/models {free_mode, providers:[{index,
  // prefix, display_name, models:[{index,id,upstream_id,context_window,enabled,is_free}]}]}.
  function isFreeId(id) {
    var s = String(id || "").toLowerCase();
    return s.slice(-5) === "-free" || s.slice(-5) === ":free";
  }

  function flattenCatalog(data) {
    var flat = [];
    state.hidePaid = !!(data && data.hide_paid);
    var pros = Array.isArray(data) ? data : (data && Array.isArray(data.providers) ? data.providers : []);
    pros.forEach(function (p) {
      var pIdx = p.index;
      (Array.isArray(p.models) ? p.models : []).forEach(function (m) {
        flat.push({
          id: m.id,
          upstream: m.upstream_id,
          provider: p.display_name,
          prefix: p.prefix,
          context: m.context_window || 0,
          enabled: m.enabled !== false,
          free: m.is_free !== undefined ? !!m.is_free : isFreeId(m.id),
          reasoning: !!m.reasoning,
          levels: m.reasoning_levels !== undefined ? String(m.reasoning_levels || "") : "",
          pIndex: pIdx,
          mIndex: m.index,
        });
      });
    });
    // Activated (enabled) models first; stable within each group.
    flat.sort(function (a, b) {
      return (a.enabled === b.enabled) ? 0 : (a.enabled ? -1 : 1);
    });
    syncHidePaid();
    return flat;
  }

  function syncHidePaid() {
    var t = byId("hide-paid-toggle");
    if (t) {
      t.checked = !!state.hidePaid;
      t.setAttribute("aria-pressed", state.hidePaid ? "true" : "false");
    }
  }

  function providerUpByName(name) {
    for (var i = 0; i < state.providers.length; i++) {
      if (state.providers[i].display_name === name) {
        return providerHealth(state.providers[i]).healthy > 0;
      }
    }
    return null;
  }

  function modelStatus(m) {
    var up = providerUpByName(m.provider);
    return up === null ? "unknown" : (up ? "up" : "down");
  }

  function renderModels() {
    var body = byId("models-body");
    var count = byId("models-count");
    var list = state.modelsCache;
    var q = state.modelsQuery;
    var f = state.modelsFilter;
    var rows = list.filter(function (m) {
      if (f === "all") return true;
      if (f === "on") return m.enabled;
      if (f === "off") return !m.enabled;
      if (f === "free") return m.free;
      if (f === "reasoning") return m.reasoning;
      return modelStatus(m) === f;
    }).filter(function (m) {
      if (!q) return true;
      var hay = String((m.id || "") + " " + (m.provider || "") + " " + (m.upstream || "")).toLowerCase();
      return hay.indexOf(q) >= 0;
    });
    var onCount = list.filter(function (m) { return m.enabled; }).length;
    var freeCount = list.filter(function (m) { return m.free; }).length;
    var hiddenCount = list.length - onCount;
    if (count) {
      count.textContent = Math.min(rows.length, MODELS_CAP) + " shown of " + rows.length + " matches · " + onCount + " enabled in this catalog";
    }
    if (!body) return;
    clearNode(body);
    if (!list.length) {
      var tr0 = el("tr");
      var td0 = el("td", "No models yet. Press Refresh to fetch from the providers.");
      td0.colSpan = 5;
      tr0.appendChild(td0);
      body.appendChild(tr0);
      return;
    }
    if (!rows.length) {
      var tr1 = el("tr");
      var td1 = el("td", "No models match.");
      td1.colSpan = 5;
      tr1.appendChild(td1);
      body.appendChild(tr1);
      return;
    }
    rows.slice(0, MODELS_CAP).forEach(function (m) {
      var tr = el("tr");
      tr.classList.add("model-row");
      if (!m.enabled) tr.classList.add("is-off");
      if (!m.free) tr.classList.add("is-paid");
      // Selection checkbox.
      var tdSel = el("td");
      var cb = el("input");
      cb.type = "checkbox";
      cb.className = "model-check";
      cb.checked = m.enabled;
      cb.setAttribute("aria-label", "Toggle " + m.id);
      cb.addEventListener("change", function () {
        toggleModel(m, cb.checked);
      });
      tdSel.appendChild(cb);
      tr.appendChild(tdSel);
      // Model id + FREE badge.
      var tdId = el("td");
      tdId.appendChild(el("span", m.id, "mono"));
      if (m.free) tdId.appendChild(el("span", "FREE", "badge badge-free"));
      tr.appendChild(tdId);
      tr.appendChild(el("td", m.provider, "muted"));
      // Reasoning levels cell (editable, comma-separated).
      tr.appendChild(levelsCell(m));
      // Editable context cell.
      tr.appendChild(contextCell(m));
      body.appendChild(tr);
    });
  }

  // Reasoning levels cell: shows the comma-joined levels ("max,high,low,none"
  // by default); click to edit, Enter saves, Esc cancels.
  function levelsCell(m) {
    var td = el("td", null, "mono muted ctx-cell");
    var label = el("span", m.levels ? m.levels.split(",").join(" / ") : "Not specified", "ctx-value");
    label.title = "Click to edit reasoning levels (comma separated)";
    label.setAttribute("role", "button");
    label.setAttribute("tabindex", "0");
    td.appendChild(label);
    function edit() {
      clearNode(td);
      var inp = el("input");
      inp.type = "text";
      inp.className = "ctx-input mono";
      inp.value = m.levels || "";
      inp.placeholder = "Upstream-supported levels, e.g. low,high";
      inp.setAttribute("aria-label", "Reasoning levels for " + m.id);
      td.appendChild(inp);
      inp.focus();
      inp.select();
      var done = false;
      function commit(save) {
        if (done) return;
        done = true;
        var v = String(inp.value || "").trim();
        if (save && v !== m.levels) {
          apiFetch("/api/models/" + m.pIndex + "/" + m.mIndex, {
            method: "PATCH",
            body: { reasoning_levels: v },
          }).then(function (r) {
            m.levels = (r && r.reasoning_levels !== undefined) ? String(r.reasoning_levels) : v;
            toast("ok", "Reasoning levels set: " + m.id);
            renderModels();
          }).catch(function () {
            renderModels();
          });
        } else {
          renderModels();
        }
      }
      inp.addEventListener("keydown", function (ev) {
        if (ev.key === "Enter") commit(true);
        if (ev.key === "Escape") commit(false);
      });
      inp.addEventListener("blur", function () { commit(true); });
    }
    label.addEventListener("click", edit);
    label.addEventListener("keydown", function (ev) {
      if (ev.key === "Enter" || ev.key === " ") edit();
    });
    return td;
  }

  function contextCell(m) {    var td = el("td", null, "mono muted ctx-cell");
    var label = el("span", m.context > 0 ? String(m.context) : "set", "ctx-value");
    label.title = "Click to edit context limit";
    label.setAttribute("role", "button");
    label.setAttribute("tabindex", "0");
    td.appendChild(label);
    function edit() {
      clearNode(td);
      var inp = el("input");
      inp.type = "number";
      inp.className = "ctx-input mono";
      inp.value = m.context > 0 ? String(m.context) : "";
      inp.placeholder = "tokens";
      inp.min = "0";
      inp.setAttribute("aria-label", "Context limit for " + m.id);
      td.appendChild(inp);
      inp.focus();
      inp.select();
      var done = false;
      function commit(save) {
        if (done) return;
        done = true;
        var v = Math.floor(Number(inp.value));
        if (save && isFinite(v) && v >= 0 && v !== m.context) {
          apiFetch("/api/models/" + m.pIndex + "/" + m.mIndex, {
            method: "PATCH",
            body: { context_window: v },
          }).then(function () {
            m.context = v;
            toast("ok", "Context set: " + m.id + " = " + v);
            renderModels();
          }).catch(function () {
            renderModels();
          });
        } else {
          renderModels();
        }
      }
      inp.addEventListener("keydown", function (ev) {
        if (ev.key === "Enter") commit(true);
        if (ev.key === "Escape") commit(false);
      });
      inp.addEventListener("blur", function () { commit(true); });
    }
    label.addEventListener("click", edit);
    label.addEventListener("keydown", function (ev) {
      if (ev.key === "Enter" || ev.key === " ") edit();
    });
    return td;
  }

  function toggleModel(m, enabled) {
    apiFetch("/api/models/" + m.pIndex + "/" + m.mIndex, {
      method: "PATCH",
      body: { enabled: !!enabled },
    }).then(function () {
      m.enabled = !!enabled;
      toast("ok", (enabled ? "On: " : "Off: ") + m.id);
      renderModels();
    }).catch(function () { /* toasted already */ });
  }

  function setAllEnabled(enabled) {
    var list = state.modelsCache;
    if (!list.length) {
      toast("warn", "No models loaded.");
      return;
    }
    var chain = Promise.resolve();
    list.forEach(function (m) {
      if (m.enabled === enabled) return;
      chain = chain.then(function () {
        return apiFetch("/api/models/" + m.pIndex + "/" + m.mIndex, {
          method: "PATCH",
          body: { enabled: enabled },
        }).then(function () {
          m.enabled = enabled;
        });
      });
    });
    chain.then(function () {
      toast("ok", (enabled ? "Enabled " : "Disabled ") + "all models.");
      renderModels();
    }).catch(function () { /* toasted already */ });
  }

  var refreshingCatalog = false;

  function refreshCatalog(quiet) {
    if (refreshingCatalog) return;
    refreshingCatalog = true;
    var btn = byId("models-reload");
    if (btn) btn.disabled = true;
    // The refresh fetches every provider in parallel and can take a while;
    // use a long timeout and no error toast (failures are per-provider).
    apiFetch("/api/models", { method: "POST", body: {}, quiet: true, timeoutMs: 120000 })
      .then(function () {
        if (!quiet) toast("ok", "Catalog refreshed.");
        return loadModels(true);
      })
      .catch(function () { /* logged server-side; cache stays as-is */ })
      .then(function () {
        refreshingCatalog = false;
        if (btn) btn.disabled = false;
      });
  }

  function loadModels(autoRefresh) {
    // Instant: serves whatever is cached. If the catalog is still empty
    // (first run after startup), kick one background refresh.
    apiGet("/api/models", state.view !== "models").then(function (data) {
      state.modelsCache = flattenCatalog(data);
      renderModels();
      if (autoRefresh !== true && state.modelsCache.length === 0 && !refreshingCatalog) {
        refreshCatalog(true);
      }
    }).catch(function () {
      if (state.view === "models") toast("err", "Models failed to load.");
    });
  }


  /* ---------- logs + settings ---------- */

  function renderLogs(entries) {
    var term = byId("terminal");
    if (!term) return;
    var list = Array.isArray(entries) ? entries : (entries && Array.isArray(entries.logs) ? entries.logs : []);
    var f = state.logLevel;
    var kept = list.filter(function (e) {
      if (f === "all") return true;
      return normLevel(e.level) === f;
    });
    clearNode(term);
    if (!kept.length) {
      term.appendChild(el("div", list.length ? "No lines match this level." : "Console empty.", "logs-empty"));
      return;
    }
    var stuck = !state.logFollow || state.logPaused;
    var prevTop = stuck ? term.scrollTop : 0;
    kept.slice(-LOGS_LIMIT).forEach(function (e) {
      term.appendChild(el("div", logLineText(e), "log-line lvl-" + (normLevel(e.level) || "info")));
    });
    if (stuck) term.scrollTop = prevTop;
    else term.scrollTop = term.scrollHeight;
  }

  function refreshLogs(manual) {
    if (!manual && state.logPaused) return Promise.resolve(null);
    return apiGet("/api/logs/" + LOGS_LIMIT, true).then(function (data) {
      renderLogs(data);
      if (state.view === "dashboard") renderActivity(data);
      return data;
    }).catch(function () {
      return apiGet("/api/logs", true).then(function (data) {
        renderLogs(data);
        if (state.view === "dashboard") renderActivity(data);
        return data;
      }).catch(function () {
        return null;
      });
    });
  }

  function loadSettings() {
    apiGet("/api/settings", state.view !== "settings").then(function (s) {
      var d = s || {};
      var auto = byId("set-autostart");
      var cd = byId("set-cooldown");
      var to = byId("set-timeout");
      var portIn = byId("set-port");
      if (portIn && d.port !== undefined) portIn.value = String(d.port);
      if (auto) auto.checked = !!d.auto_start;
      if (cd && d.cooldown_secs !== undefined) cd.value = String(d.cooldown_secs);
      if (to && d.timeout_ms !== undefined) to.value = String(Math.round(d.timeout_ms / 1000));
      var dirty = byId("settings-dirty");
      if (dirty) dirty.hidden = true;
    }).catch(function () { /* quiet unless on view */ });
  }

  function submitSettings() {
    var auto = byId("set-autostart");
    var cd = byId("set-cooldown");
    var to = byId("set-timeout");
    var cooldown = cd ? Math.floor(Number(cd.value)) : NaN;
    var timeoutS = to ? Number(to.value) : NaN;
    if (!isFinite(cooldown) || cooldown < 1 || cooldown > 86400) {
      toast("warn", "Cooldown must be 1-86400 secs.");
      return;
    }
    if (!isFinite(timeoutS) || timeoutS < 1 || timeoutS > 600) {
      toast("warn", "Timeout must be 1-600 secs.");
      return;
    }
    var portIn = byId("set-port");
    var port = portIn ? Math.floor(Number(portIn.value)) : NaN;
    if (!isFinite(port) || port < 1 || port > 65535) {
      toast("warn", "Port must be 1-65535.");
      return;
    }
    var body = {
      port: port,
      auto_start: auto ? !!auto.checked : false,
      cooldown_secs: cooldown,
      timeout_ms: Math.round(timeoutS * 1000),
    };
    apiFetch("/api/settings", { method: "PUT", body: body }).then(function () {
      toast("ok", "Settings saved.");
      var dirty = byId("settings-dirty");
      if (dirty) dirty.hidden = true;
      return refreshStatus(false);
    }).catch(function () { /* toasted already */ });
  }

  /* ---------- polling ---------- */

  function schedulePoll(ms) {
    if (state.pollTimer) clearTimeout(state.pollTimer);
    state.pollTimer = setTimeout(pollTick, ms);
  }

  function pollTick() {
    if (document.hidden) {
      schedulePoll(POLL_BASE_MS);
      return;
    }
    refreshStatus(true).then(function () {
      if (state.view === "dashboard") return refreshLogs(false);
      return null;
    }).then(function () {
      state.pollDelay = POLL_BASE_MS;
      schedulePoll(state.pollDelay);
    }).catch(function () {
      state.pollDelay = Math.min(state.pollDelay * 2, POLL_MAX_MS);
      schedulePoll(state.pollDelay);
    });
  }

  function initUpdates() {
    var button = byId("app-update"), area = byId("update-area"), busy = false, installing = false, attempts = 0;
    if (!button || !area) return;
    function poll() {
      fetch("/api/update").then(function (r) { if (!r.ok) throw new Error("unavailable"); return r.json(); }).then(function (data) {
        area.hidden = !data.available;
        setText("update-version", data.version);
        busy = data.phase === "downloading" || data.phase === "ready";
        installing = installing || busy;
        button.disabled = busy;
        setText("update-label", data.phase === "ready" ? "Restarting…" : busy ? "Downloading…" : "Update");
        if (data.phase === "failed") { installing = false; toast("err", data.message); button.title = data.message; }
        if (installing && data.current === window.freeproUpdateVersion) { window.location.reload(); return; }
        if (data.available) window.freeproUpdateVersion = data.version.replace(/^v/, "");
        if (data.phase === "checking" || busy) setTimeout(poll, 1000);
      }).catch(function () { if (installing && ++attempts < 120) setTimeout(poll, 1000); });
    }
    button.addEventListener("click", function () {
      if (busy) return;
      busy = true; button.disabled = true;
      apiGet("/api/quick-adds/kimi", true).then(function (data) {
        return apiFetch("/api/update", { method:"POST", body:{token:data.token}, quiet:true, retry409:0 });
      }).then(function () { installing = true; poll(); }).catch(function () { busy = false; button.disabled = false; toast("err", "Could not start the update. Please retry."); });
    });
    poll();
  }

  /* ---------- init ---------- */

  function init() {
    initUpdates();
    initUsage();
    initRouter();
    var kimiAdd = byId("kimi-add-update");
    if (kimiAdd) kimiAdd.addEventListener("click", applyQuickAdd);
    var tgl = byId("proxy-toggle");
    if (tgl) tgl.addEventListener("click", toggleServer);
    var endpointCopy = byId("copy-endpoint");
    if (endpointCopy) endpointCopy.addEventListener("click", copyUrl);
    var cp = byId("copy-url");
    if (cp) cp.addEventListener("click", copyUrl);
    var port = byId("port-input");
    if (port) {
      port.addEventListener("change", applyPort);
      port.addEventListener("keydown", function (ev) {
        if (ev.key === "Enter") applyPort();
      });
    }
    qsa('[data-action="shutdown"]').forEach(function (b) {
      b.addEventListener("click", shutdownServer);
    });
    qsa('[data-action="ping"]').forEach(function (b) {
      b.addEventListener("click", pingAll);
    });
    qsa('[data-action="refresh-all"]').forEach(function (b) {
      b.addEventListener("click", function () {
        refreshStatus(false).then(loadProviders).catch(function () { /* toasted */ });
        if (state.view === "models") loadModels();
        if (state.view === "settings") {
          loadSettings();
        }
      });
    });
    qsa('[data-action="refresh-activity"]').forEach(function (b) {
      b.addEventListener("click", function () {
        refreshLogs(true);
      });
    });
    var padd = byId("provider-add");
    if (padd) padd.addEventListener("click", addProvider);
    var psearch = byId("provider-search");
    if (psearch) psearch.addEventListener("input", renderProviders);
    var bulk = qs('[data-action="bulk-import"]');
    if (bulk) bulk.addEventListener("click", bulkImport);
    var msearch = byId("models-search");
    if (msearch) msearch.addEventListener("input", function () {
      state.modelsQuery = String(msearch.value || "").toLowerCase().trim();
      renderModels();
    });
    qsa("[data-filter-status]").forEach(function (b) {
      b.addEventListener("click", function () {
        state.modelsFilter = b.getAttribute("data-filter-status") || "all";
        qsa("[data-filter-status]").forEach(function (x) {
          var on = x === b;
          x.classList.toggle("is-active", on);
          x.setAttribute("aria-pressed", on ? "true" : "false");
        });
        renderModels();
      });
    });
    var mrel = byId("models-reload");
    if (mrel) mrel.addEventListener("click", refreshCatalog);
    var allOn = byId("models-all-on");
    if (allOn) allOn.addEventListener("click", function () { setAllEnabled(true); });
    var allOff = byId("models-all-off");
    if (allOff) allOff.addEventListener("click", function () { setAllEnabled(false); });
    var hideT = byId("hide-paid-toggle");
    if (hideT) hideT.addEventListener("change", function () {
      var on = !!hideT.checked;
      apiFetch("/api/settings", { method: "PUT", body: { hide_paid: on } }).then(function () {
        state.hidePaid = on;
        return loadModels();
      }).catch(syncHidePaid);
    });
    qsa('[data-action="logs-pause"]').forEach(function (b) {
      b.addEventListener("click", function () {
        state.logPaused = !state.logPaused;
        b.textContent = state.logPaused ? "Resume" : "Pause";
        b.setAttribute("aria-pressed", state.logPaused ? "true" : "false");
        if (!state.logPaused) refreshLogs(true);
      });
    });
    qsa('[data-action="logs-follow"]').forEach(function (b) {
      b.addEventListener("click", function () {
        state.logFollow = !state.logFollow;
        b.classList.toggle("is-active", state.logFollow);
        b.setAttribute("aria-pressed", state.logFollow ? "true" : "false");
        if (state.logFollow) {
          var term = byId("terminal");
          if (term) term.scrollTop = term.scrollHeight;
        }
      });
    });
    qsa('[data-action="logs-clear"]').forEach(function (b) {
      b.addEventListener("click", function () {
        var term = byId("terminal");
        if (term) clearNode(term);
      });
    });
    var lvl = byId("log-level");
    if (lvl) lvl.addEventListener("change", function () {
      state.logLevel = String(lvl.value || "all").toLowerCase();
      refreshLogs(true);
    });
    var form = byId("settings-form");
    if (form) {
      form.addEventListener("submit", function (ev) {
        ev.preventDefault();
        submitSettings();
      });
      form.addEventListener("input", function () {
        var dirty = byId("settings-dirty");
        if (dirty) dirty.hidden = false;
      });
    }
    qsa('[data-action="settings-save"]').forEach(function (b) {
      if (b.type !== "submit") b.addEventListener("click", function (ev) {
        ev.preventDefault();
        submitSettings();
      });
    });
    refreshStatus(true).then(function () {
      if (state.view === "providers") loadProviders();
      if (state.view === "models") loadModels();
      if (state.view === "settings") {
        loadSettings();
      }
    }).catch(function () { /* poll chain retries */ });
    document.addEventListener("visibilitychange", function () {
      if (!document.hidden) {
        state.pollDelay = POLL_BASE_MS;
        schedulePoll(100);
      }
    });
    schedulePoll(POLL_BASE_MS);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
