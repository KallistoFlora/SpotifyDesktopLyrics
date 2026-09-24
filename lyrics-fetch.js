'use strict';
// 歌词抓取器 v3（被 lyrics-overlay.ps1 通过子进程调用）
// 用法: node lyrics-fetch.js <请求json> <输出json> [缓存json]
// 请求: { artist, title, album, duration }
// 输出: { ok, src, name, lines: [{ t, s, tr }], transCount, transRate, matchInfo, cached }
//
// v3 改进：
//  1) 网易云候选按「时长最接近 + 歌手名匹配」挑，避免搜到 live/翻唱版
//  2) 翻译配对两轮：严格 ±0.8s -> 单调顺序 ±3.5s（两来源时间戳常差 1~2 秒）
//  3) 本地缓存：命中的曲子直接返回，避免反复请求导致网易云限流（"翻译时有时无"的主因）
//     有翻译的结果缓存 60 天；没翻译的结果只缓存 6 小时（以便稍后重试）

const fs = require('fs');
const path = require('path');

function out(p, obj) { try { fs.writeFileSync(p, JSON.stringify(obj), 'utf8'); } catch (e) { } }
function norm(s) { return String(s || '').replace(/\s+/g, ''); }

function parseLrc(lrc) {
    if (!lrc) return [];
    const rx = /^\[(\d+):(\d+(?:[.:]\d+)?)\](.*)$/;
    const lines = [];
    for (const raw of String(lrc).split(/\r?\n/)) {
        const m = rx.exec(raw.trim());
        if (!m) continue;
        const sec = parseInt(m[1], 10) * 60 + parseFloat(m[2].replace(':', '.'));
        const txt = (m[3] || '').trim();
        if (txt) lines.push({ t: sec, s: txt });
    }
    lines.sort((a, b) => a.t - b.t);
    return lines;
}

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function jget(url, ms, headers) {
    const r = await fetch(url, {
        signal: AbortSignal.timeout(ms),
        headers: Object.assign({ 'User-Agent': UA, Accept: 'application/json' }, headers || {}),
    });
    const text = await r.text();
    return { status: r.status, text };
}

// ---------- 翻译配对（两轮） ----------
function attachTrans(lines, transLines) {
    const info = { pass1: 0, pass2: 0, total: 0 };
    if (!lines || !lines.length || !transLines || !transLines.length) return info;
    const used = new Array(transLines.length).fill(false);
    const ok = (ln, tr) => tr && norm(tr.s) && norm(tr.s) !== norm(ln.s);

    for (const ln of lines) {                       // 第一轮：严格 ±0.8s
        let best = -1, bestD = 1e9;
        for (let i = 0; i < transLines.length; i++) {
            if (used[i]) continue;
            const d = Math.abs(transLines[i].t - ln.t);
            if (d < bestD) { bestD = d; best = i; }
        }
        if (best >= 0 && bestD <= 0.8 && ok(ln, transLines[best])) {
            ln.tr = transLines[best].s; used[best] = true; info.pass1++;
        }
    }
    let j = 0;
    for (const ln of lines) {                       // 第二轮：单调顺序 ±3.5s
        if (ln.tr) continue;
        while (j < transLines.length && transLines[j].t < ln.t - 3.5) j++;
        let k = j;
        while (k < transLines.length && transLines[k].t <= ln.t + 3.5) {
            if (!used[k] && ok(ln, transLines[k])) {
                ln.tr = transLines[k].s; used[k] = true; info.pass2++;
                j = k + 1; break;
            }
            k++;
        }
    }
    let hit = 0;
    for (const ln of lines) if (ln.tr) hit++;
    info.total = lines.length ? hit / lines.length : 0;
    info.hit = hit;
    return info;
}

// ---------- LRCLIB ----------
async function lrclibGet(q) {
    try {
        const r = await jget('https://lrclib.net/api/get?artist_name=' + encodeURIComponent(q.artist) +
            '&track_name=' + encodeURIComponent(q.title) + '&album_name=' + encodeURIComponent(q.album || '') +
            '&duration=' + Math.round(q.duration || 0), 12000);
        if (r.status !== 200) return null;
        const j = JSON.parse(r.text);
        const lines = parseLrc(j.syncedLyrics);
        if (!lines.length) return null;
        return { src: 'lrclib/get', name: (j.artistName || '') + ' - ' + (j.trackName || ''), lines };
    } catch { return null; }
}

async function lrclibSearch(q) {
    try {
        const r = await jget('https://lrclib.net/api/search?q=' + encodeURIComponent(q.artist + ' ' + q.title), 12000);
        if (r.status !== 200) return null;
        const arr = JSON.parse(r.text);
        if (!Array.isArray(arr)) return null;
        const cand = arr.filter((x) => x.syncedLyrics);
        if (!cand.length) return null;
        cand.sort((a, b) => Math.abs((a.duration || 0) - (q.duration || 0)) - Math.abs((b.duration || 0) - (q.duration || 0)));
        const lines = parseLrc(cand[0].syncedLyrics);
        if (!lines.length) return null;
        return { src: 'lrclib/search', name: (cand[0].artistName || '') + ' - ' + (cand[0].trackName || ''), lines };
    } catch { return null; }
}

// ---------- 网易云（候选打分 + 失败重试一次） ----------
async function neteaseOnce(q) {
    const h = { 'Referer': 'https://music.163.com/', 'Cookie': 'appver=2.0.2' };
    const s = await jget('https://music.163.com/api/search/get/web?csrf_token=&s=' +
        encodeURIComponent(q.artist + ' ' + q.title) + '&type=1&offset=0&total=true&limit=10', 12000, h);
    if (s.status !== 200) return null;
    const songs = (JSON.parse(s.text).result || {}).songs || [];
    if (!songs.length) return null;

    const want = q.duration || 0;
    const score = (song) => {
        let sc = song.duration ? Math.min(Math.abs(song.duration / 1000 - want), 60) : 60;
        const an = norm(((song.artists || [])[0] || {}).name), qa = norm(q.artist);
        if (qa && an && !(an.includes(qa) || qa.includes(an))) sc += 25;
        if (norm(song.name) !== norm(q.title)) sc += 3;
        return sc;
    };
    songs.sort((a, b) => score(a) - score(b));

    // 依次尝试前几个候选，优先返回「带翻译」的那一个
    let fallback = null;
    for (const song of songs.slice(0, 4)) {
        const ly = await jget('https://music.163.com/api/song/lyric?id=' + song.id + '&lv=-1&kv=-1&tv=-1', 12000, h);
        if (ly.status !== 200) continue;
        let lj; try { lj = JSON.parse(ly.text); } catch { continue; }
        const lines = parseLrc(lj.lrc && lj.lrc.lyric);
        if (!lines.length) continue;
        const trans = parseLrc(lj.tlyric && lj.tlyric.lyric);
        const artist = ((song.artists || [])[0] || {}).name || '';
        const info = trans.length ? attachTrans(lines, trans) : { pass1: 0, pass2: 0, total: 0, hit: 0 };
        const item = { src: 'netease', name: artist + ' - ' + song.name, duration: song.duration ? song.duration / 1000 : 0, lines, trans, transInfo: info };
        if (info.hit > 0) return item;          // 找到带翻译的，直接用
        if (!fallback) fallback = item;         // 记下第一个可用的作为兜底
    }
    return fallback;
}

async function netease(q) {
    let r = null;
    for (let i = 0; i < 2 && !r; i++) {         // 失败重试一次（限流常是瞬时的）
        try { r = await neteaseOnce(q); } catch { r = null; }
        if (!r) await sleep(700);
    }
    return r;
}

// ---------- 缓存 ----------
function cacheKey(q) { return (norm(q.artist) + '|' + norm(q.title) + '|' + Math.round(q.duration || 0)).toLowerCase(); }
function cacheLoad(p) { try { return JSON.parse(fs.readFileSync(p, 'utf8')) || {}; } catch { return {}; } }
function cacheSave(p, c) { try { fs.writeFileSync(p, JSON.stringify(c), 'utf8'); } catch { } }

// ---------- 主流程 ----------
(async () => {
    const reqPath = process.argv[2], outPath = process.argv[3];
    const cachePath = process.argv[4] || path.join(path.dirname(outPath), 'lyrics-cache.json');

    let q = {};
    try { q = JSON.parse(fs.readFileSync(reqPath, 'utf8')); }
    catch (e) { return out(outPath, { ok: false, err: 'bad request: ' + e.message }); }

    const key = cacheKey(q);
    const cache = cacheLoad(cachePath);
    const now = Math.floor(Date.now() / 1000);

    const hit = cache[key];
    if (hit && hit.lines && hit.lines.length && (now - hit.ts) < (hit.ttl || 0)) {
        return out(outPath, Object.assign({}, hit, { cached: true }));
    }

    let base = await lrclibGet(q);
    if (!base) base = await lrclibSearch(q);
    const ne = await netease(q);

    let result = null, info = { pass1: 0, pass2: 0, total: 0, hit: 0 };
    if (base) {
        result = base;
        if (ne && ne.trans && ne.trans.length) {
            info = attachTrans(base.lines, ne.trans);
            result.transSrc = ne.name;
        }
    } else if (ne && ne.lines && ne.lines.length) {
        result = { src: ne.src, name: ne.name, lines: ne.lines };
        info = ne.transInfo || info;
    }

    if (!result || !result.lines.length) return out(outPath, { ok: false, err: 'no lyrics found' });

    // 有翻译但配对率过低 -> 丢弃翻译（宁缺勿错）。阈值放宽到 20%：
    // 两轮配对后仍然很低，通常说明这首本来就几乎没翻译行，而不是错位。
    if (info.hit > 0 && info.total < 0.20) {
        for (const ln of result.lines) delete ln.tr;
        info.dropped = true;
    }

    const transCount = result.lines.filter((l) => l.tr).length;
    const payload = {
        ok: true,
        src: result.src,
        name: result.name,
        transSrc: result.transSrc || '',
        transCount,
        transRate: transCount / result.lines.length,
        matchInfo: info,
        lines: result.lines,
        cached: false,
        ts: now,
        // 有翻译缓存 60 天；没有就只缓存 6 小时，方便稍后重试（网易云限流是瞬时的）
        ttl: transCount > 0 ? 60 * 24 * 3600 : 6 * 3600,
    };
    cache[key] = {
        ok: true, src: payload.src, name: payload.name, transSrc: payload.transSrc,
        transCount: payload.transCount, transRate: payload.transRate,
        matchInfo: payload.matchInfo, lines: payload.lines, ts: payload.ts, ttl: payload.ttl,
    };
    cacheSave(cachePath, cache);
    out(outPath, payload);
})();
