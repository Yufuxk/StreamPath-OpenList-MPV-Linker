// 为现有 Profile probe 准备隔离数据，并按实际操作时间汇总帧。
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const [command, ...args] = process.argv.slice(2);
const percentile = (values, p) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)] ?? null;
};
if (command === 'prepare') {
  const [snapshot, destination] = args;
  if (!path.basename(destination).startsWith('film-scrape-lab-')) {
    throw new Error('An isolated film-scrape-lab-* directory is required');
  }
  fs.mkdirSync(destination, { recursive: true });
  const input = new DatabaseSync(snapshot, { readOnly: true });
  const templates = input.prepare('SELECT * FROM works WHERE tmdb_id > 0 ORDER BY id').all();
  input.close();
  const output = path.join(destination, 'seed.db');
  fs.copyFileSync(snapshot, output);
  const db = new DatabaseSync(output);
  db.exec('PRAGMA foreign_keys=OFF; BEGIN');
  for (const { name } of db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").all()) {
    db.exec(`DELETE FROM "${name}"`);
  }
  let state = 20261020;
  const random = n => { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; return state % n; };
  const insert = (table, row) => db.prepare(`INSERT INTO ${table} (${Object.keys(row).join(',')}) VALUES (${Object.keys(row).map(() => '?').join(',')})`).run(...Object.values(row));
  const manifest = [];
  const sizes = [];
  insert('catalog_settings', { id: 1, metadata_language: 'zh-CN', probe_mode: 'playback' });
  insert('catalog_preferences', { key: 'daily_selection', value_json: JSON.stringify({ date: new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Shanghai' }).format(new Date()), ids: Array.from({ length: 10 }, (_, i) => i + 1) }) });
  let workId = 0;
  for (const [type, count] of [['tv', 160], ['movie', 200]]) {
    const rootId = type === 'tv' ? 1 : 2;
    const rootPath = type === 'tv' ? 'Library/Series' : 'Library/Movies';
    insert('catalog_roots', { id: rootId, source_id: 'fixture', source_kind: 'webdav', root_path: rootPath, root_path_key: rootPath, media_type: type, display_name: type, scan_generation: 1, scan_status: 'idle', created_at: 42 });
    const source = templates.filter(w => w.media_type === type);
    if (!source.length) throw new Error(`Missing ${type} metadata templates`);
    for (let i = 0; i < count; i++) {
      const row = { ...source[i % source.length] };
      row.id = ++workId;
      row.tmdb_id = 900000 + workId;
      row.identity_key = `tmdb:${type}:${row.tmdb_id}`;
      row.title = `Fixture ${String(workId).padStart(4, '0')} ${row.title}`;
      row.original_title = row.title;
      row.metadata_language = 'zh-CN';
      const metadata = JSON.parse(row.metadata_json);
      metadata.belongs_to_collection = null;
      row.metadata_json = JSON.stringify(metadata);
      sizes.push(Buffer.byteLength(row.metadata_json));
      insert('works', row);
      let prefix = rootPath;
      const layers = ['Region', 'Year', 'Genre', 'Archive', 'Studio', 'Collection'];
      for (let depth = 0, n = random(6); depth < n; depth++) {
        prefix += `/${layers[depth]} ${random(9)}`;
      }
      prefix += `/Work ${workId} [tmdb-${row.tmdb_id}]`;
      const countFiles = type === 'tv' ? 25 : 1;
      const versions = random(3) + 1;
      for (let episode = 1; episode <= countFiles; episode++) {
        const season = episode > 12 ? 2 : 1;
        const number = episode > 12 ? episode - 12 : episode;
        let parent = prefix;
        if (versions > 1) parent += `/Version ${episode % versions + 1}`;
        if (type === 'tv') {
          parent += `/${['Season', 'Disc', 'Episodes'][i % 3]} ${String(season).padStart(2, '0')}`;
          if (i % 5 === 0) parent += `/Part ${Math.ceil(number / 4)}`;
        } else if (i % 4 === 0) parent += '/BDRip/Main Feature';
        const name = type === 'tv' ? `Fixture.S${String(season).padStart(2, '0')}E${String(number).padStart(2, '0')}.strm` : `Fixture.${row.year ?? 2020}.strm`;
        const relative = `${parent}/${name}`;
        insert('resources', { root_id: rootId, relative_path: relative, path_key: relative, parent_path: parent, name, media_kind: 'strm', work_id: workId, binding_origin: 'explicit', binding_version: 0, season_number: null, episode_number: null, episode_mapping_origin: 'unset', availability: 'present', last_seen_generation: 1, created_at: workId });
        manifest.push({ rootId, path: relative, parent, name, type, workId, season: type === 'tv' ? season : null, episode: type === 'tv' ? number : null });
      }
      if (type === 'tv') {
        for (const season of [1, 2]) insert('season_metadata', { work_id: workId, season_number: season, metadata_language: 'zh-CN', metadata_json: JSON.stringify({ season_number: season, episodes: [] }), metadata_fetched_at: 42 });
      }
    }
  }
  const artwork = path.join(destination, 'artwork');
  const cover = fs.readdirSync(artwork).filter(name => name.endsWith('.img')).sort()[0];
  if (!cover) throw new Error('A copied artwork cache is required');
  for (const rootId of [1, 2]) insert('root_covers', { root_id: rootId, custom_path: path.join(artwork, cover) });
  db.exec('COMMIT; PRAGMA foreign_keys=ON');
  const violations = db.prepare('PRAGMA foreign_key_check').all();
  if (violations.length) throw new Error('Fixture foreign key violation');
  db.close();
  const directories = new Set();
  for (const file of manifest) {
    const parts = file.parent.split('/');
    for (let i = 1; i <= parts.length; i++) directories.add(parts.slice(0, i).join('/'));
  }
  const stats = { seed: 20261020, episodes: 4000, movies: 200, works: workId, directories: directories.size, minDepth: Math.min(...manifest.map(f => f.parent.split('/').length)), maxDepth: Math.max(...manifest.map(f => f.parent.split('/').length)), metadataBytes: { p50: percentile(sizes, .5), p95: percentile(sizes, .95), max: Math.max(...sizes) } };
  fs.writeFileSync(path.join(destination, 'fixture.json'), JSON.stringify({ stats, files: manifest }));
  console.log(JSON.stringify(stats));
} else if (command === 'summarize') {
  const summaries = args.map(file => {
    const data = JSON.parse(fs.readFileSync(file));
    const phases = {};
    for (const phase of ['before', 'before-scroll', 'scraping', 'scraping-scroll', 'after', 'after-scroll']) {
      const operations = data.operations.filter(o => o.phase === phase);
      if (!operations.length) continue;
      const frames = data.frames.filter(f => operations.some(o => f.startUs >= o.startUs && f.startUs <= o.endUs));
      const budget = 1e6 / data.refreshRate;
      const metric = field => ({ p50: percentile(frames.map(f => f[field] / 1000), .5), p95: percentile(frames.map(f => f[field] / 1000), .95), p99: percentile(frames.map(f => f[field] / 1000), .99), max: Math.max(...frames.map(f => f[field] / 1000)) });
      const over = frames.filter(f => f.buildUs > budget || f.rasterUs > budget).length;
      const refreshes = data.refreshes.filter(r => operations.some(o => r.startUs >= o.startUs && r.startUs <= o.endUs));
      phases[phase] = { frames: frames.length, ui: metric('buildUs'), raster: metric('rasterUs'), span: metric('totalUs'), overBudget: over, overBudgetRatio: frames.length ? over / frames.length : 0, lateUi: frames.filter(f => f.vsyncOverheadUs + f.buildUs > budget).length, refreshes: refreshes.length, refreshP95Ms: percentile(refreshes.map(r => r.durationUs / 1000), .95), ...data.samples[phase] };
    }
    return { file, mode: data.mode, viewport: data.viewport, dpr: data.dpr, refreshRate: data.refreshRate, backdrop: data.backdrop, loadedWorks: data.loadedWorks ?? 60, phases, processed: data.processed, scrapeMs: (data.scrapeEndUs - data.scrapeStartUs) / 1000, actualNetworkRequests: data.actualNetworkRequests };
  });
  console.log(JSON.stringify(summaries, null, 2));
} else if (command === 'cpu') {
  console.log(JSON.stringify(args.map(file => {
    const data = JSON.parse(fs.readFileSync(file));
    return { file, sampleCount: data.sampleCount, unavailable: data.unavailable,
      hottest: data.functions?.filter(f => f.exclusiveTicks > 0)
        .sort((a, b) => b.exclusiveTicks - a.exclusiveTicks).slice(0, 20)
        .map(f => ({ name: f.function?.name, url: f.resolvedUrl, exclusiveTicks: f.exclusiveTicks, inclusiveTicks: f.inclusiveTicks })),
    };
  }), null, 2));
} else {
  throw new Error('Expected prepare, summarize or cpu');
}
