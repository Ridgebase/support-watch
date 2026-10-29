// Closed Message Center messages, shared by everyone who uses the page (Tech watch tab, Service changes).
// GET /api/closed: [{Id, Title, By, At}]   POST /api/closed {id, title}: close   DELETE /api/closed?id=MC123: reopen
// Only the Static Web App's signed-in "reader" users get here (staticwebapp.config.json, route /*); "By" is their sign-in.
// Storage: table closedchanges in stsupportwatchsemo, reached with a table SAS URL (app setting CLOSED_TABLE_SAS, expiry in EXPIRIES).
// ponytail: plain REST with fetch, no npm package; one page of results (1,000 rows), far more than the closed messages of 60 days.
const sas = process.env.CLOSED_TABLE_SAS || '';
const [base, query] = sas.split('?');
const entity = id => `${base}(PartitionKey='mc',RowKey='${id}')?${query}`;
const headers = { Accept: 'application/json;odata=nometadata', 'Content-Type': 'application/json', 'x-ms-version': '2019-02-02' };

module.exports = async function (context, req) {
  const reply = (status, body) => { context.res = { status, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }; };
  if (!base || !query) return reply(500, { error: 'CLOSED_TABLE_SAS is not set' });
  const principal = req.headers['x-ms-client-principal'];
  const user = principal ? JSON.parse(Buffer.from(principal, 'base64').toString('utf8')).userDetails : '';
  try {
    if (req.method === 'GET') {
      const r = await fetch(`${base}()?${query}`, { headers });
      if (!r.ok) throw new Error(`table read: ${r.status} ${await r.text()}`);
      return reply(200, (await r.json()).value.map(e => ({ Id: e.RowKey, Title: e.Title, By: e.By, At: e.At })));
    }
    const id = String((req.method === 'DELETE' ? req.query.id : req.body && req.body.id) || '');
    if (!/^MC\d{3,12}$/.test(id)) return reply(400, { error: 'id must be a Message Center id (MC123456)' });   // also keeps the id safe in the entity URL
    if (req.method === 'POST') {
      const row = { Title: String(req.body.title || '').slice(0, 300), By: user, At: new Date().toISOString() };
      const r = await fetch(entity(id), { method: 'PUT', headers, body: JSON.stringify(row) });   // insert or replace
      if (!r.ok) throw new Error(`table write: ${r.status} ${await r.text()}`);
      return reply(200, { Id: id, ...row });
    }
    if (req.method === 'DELETE') {
      const r = await fetch(entity(id), { method: 'DELETE', headers: { ...headers, 'If-Match': '*' } });
      if (!r.ok && r.status !== 404) throw new Error(`table delete: ${r.status} ${await r.text()}`);
      return reply(200, { Id: id });
    }
    return reply(405, { error: 'GET, POST or DELETE' });
  } catch (e) {
    context.log.error(e.message);
    return reply(502, { error: e.message });
  }
};
