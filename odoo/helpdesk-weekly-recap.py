# Odoo scheduled action: weekly recap per client, one mail per client with only that client's tickets and projects
# (a project belongs to a client through its Customer field; projects without a customer are never listed).
# Runs inside Odoo Online (ridg-support-new.odoo.com, saas 19.4), no external tool: Settings > Technical > Automation >
# Scheduled Actions (developer mode): Model Helpdesk Ticket, every 1 Weeks, next execution Monday 11:00 UTC (07:00 Eastern
# in summer), Action to do: Execute Code, this code.
# Recipients: RECIPIENTS below maps the client (commercial partner name, as on the ticket) to the address; a client not listed
# gets no mail. Test for one client without waiting: run the server action with context
#   {'weekly_client': 'Séguin Morris Inc', 'weekly_to': 'adrien.polselli@ridgebase.com'}
# e.g. from a browser console on the signed-in session: fetch('/web/dataset/call_kw', {method:'POST', headers:{'Content-Type':'application/json'},
#   body: JSON.stringify({jsonrpc:'2.0', method:'call', params:{model:'ir.actions.server', method:'run', args:[[<action id>]], kwargs:{context:{...}}}})})
# Mail leaves through Odoo's queue: the "neutralization - disable emails" mail server (host "invalid") must be deleted first, or every mail stays in Exception.
# Sandbox notes: no imports (datetime and dateutil are provided), no f-strings, lambdas only.

RECIPIENTS = {
    'Séguin Morris Inc': 'adrien.polselli@ridgebase.com',
}
tz = dateutil.tz.gettz('America/Toronto')
now = datetime.datetime.now()
week_ago = now - datetime.timedelta(days=7)
local = lambda d: d.replace(tzinfo=dateutil.tz.UTC).astimezone(tz).strftime('%Y-%m-%d %H:%M') if d else ''
day = lambda d: d.replace(tzinfo=dateutil.tz.UTC).astimezone(tz).strftime('%Y-%m-%d')
esc = lambda s: (s or '').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
base = env['ir.config_parameter'].sudo().get_param('web.base.url')
PRIO = {'0': 'Low', '1': 'Medium', '2': 'High', '3': 'Urgent'}
BAD, OK, WARN, MUTED = '#e95664', '#3c8274', '#c2641a', '#76706a'
STATUS = {'on_track': ('On track', OK), 'at_risk': ('At risk', WARN), 'off_track': ('Off track', BAD), 'on_hold': ('On hold', MUTED), 'done': ('Done', OK), 'to_define': ('Not set', MUTED)}
today = now.strftime('%Y-%m-%d')
Ticket = env['helpdesk.ticket'].sudo()
Project = env['project.project'].sudo()
Task = env['project.task'].sudo()
client_of = lambda t: (t.commercial_partner_id.name or t.partner_company_name or '')
only = env.context.get('weekly_client')
targets = {only: env.context.get('weekly_to')} if only else RECIPIENTS
for c, to in targets.items():
    if not to:
        continue
    open_t = Ticket.search([('stage_id.fold', '=', False)]).filtered(lambda t: client_of(t) == c).sorted(lambda t: (-int(t.priority or '0'), t.create_date))   # New, In Progress, Waiting for Client, On Hold
    new_t = Ticket.search([('create_date', '>=', week_ago)]).filtered(lambda t: client_of(t) == c)
    done_t = Ticket.search([('close_date', '>=', week_ago), ('stage_id.fold', '=', True)]).filtered(lambda t: client_of(t) == c)   # Solved or Cancelled this week
    late = open_t.filtered(lambda t: t.sla_fail)
    pill = ('<span style="background:#fdecee;color:%s;padding:2px 8px;border-radius:10px;font-size:12px">%d past SLA</span>' % (BAD, len(late))) if late else ('<span style="background:#e9f3ee;color:%s;padding:2px 8px;border-radius:10px;font-size:12px">On track</span>' % OK)
    line = '<b>%d</b> open &middot; <b>%d</b> opened this week &middot; <b>%d</b> solved this week' % (len(open_t), len(new_t), len(done_t))
    rows = ''
    cell = 'padding:6px 8px;border-top:1px solid #e4ded7;white-space:nowrap'
    for t in open_t:
        sla = ('<span style="color:%s;font-weight:600">%s</span>' % (BAD, local(t.sla_deadline))) if t.sla_fail else (local(t.sla_deadline) or '&mdash;')
        rows += '<tr><td style="padding:6px 0;border-top:1px solid #e4ded7;white-space:nowrap"><a href="%s%s" style="color:#043f45">#%s</a></td><td style="padding:6px 8px;border-top:1px solid #e4ded7">%s</td><td style="%s">%s</td><td style="%s">%s</td><td style="%s">%s</td><td style="%s">%s</td><td style="%s">%s</td></tr>' % (
            base, t.get_portal_url(), esc(t.ticket_ref), esc(t.name), cell, esc(t.stage_id.name), cell, PRIO.get(t.priority, ''), cell, esc(t.user_id.name or 'Not assigned yet'), cell, day(t.create_date), cell, sla)
    solved = ''.join(['<tr><td style="padding:6px 0;border-top:1px solid #e4ded7;white-space:nowrap"><a href="%s%s" style="color:#043f45">#%s</a></td><td style="padding:6px 8px;border-top:1px solid #e4ded7">%s</td><td style="%s">%s</td><td style="%s">%s</td></tr>' % (
        base, t.get_portal_url(), esc(t.ticket_ref), esc(t.name), cell, esc(t.stage_id.name), cell, day(t.close_date)) for t in done_t])
    head = lambda title, cols: '<div style="color:%s;font-size:12px;margin-top:14px">%s</div><table style="width:100%%;border-collapse:collapse;font-size:13px;margin-top:6px"><tr style="color:%s;font-size:11px;text-transform:uppercase;letter-spacing:.06em">%s</tr>' % (MUTED, title, MUTED, ''.join(['<td style="padding:0 8px">%s</td>' % x for x in cols]))
    table = (head('Open tickets', ['Ticket', 'Subject', 'Stage', 'Priority', 'Handled by', 'Opened', 'SLA deadline']) + rows + '</table>') if rows else ('<div style="color:%s;margin-top:10px">No open ticket</div>' % MUTED)
    table += (head('Solved this week', ['Ticket', 'Subject', 'Stage', 'Closed']) + solved + '</table>') if solved else ''
    # Projects: the active projects whose Customer is this client. One row per project: status (the last project update), open tasks,
    # overdue tasks (deadline before today, not closed), tasks done this week, next milestone (red when past its deadline); the overdue tasks named below.
    prow = ''; overdue_names = []; n_proj = 0; n_open_k = 0; n_overdue = 0
    for p in Project.search([('partner_id', '!=', False)]).filtered(lambda p: (p.partner_id.commercial_partner_id.name or '') == c):
        tasks = Task.search([('project_id', '=', p.id)])
        open_k = tasks.filtered(lambda t: not t.is_closed)
        overdue = open_k.filtered(lambda t: t.date_deadline and str(t.date_deadline)[:10] < today)
        done_k = tasks.filtered(lambda t: t.is_closed and t.date_last_stage_update and str(t.date_last_stage_update)[:10] >= week_ago.strftime('%Y-%m-%d'))   # date_end stays empty on a task marked done, the stage date does not
        nxt = p.milestone_ids.filtered(lambda m: not m.is_reached).sorted('deadline')[:1]
        st = STATUS.get(p.last_update_status, (p.last_update_status or '', MUTED))
        mile = ('<span style="color:%s">%s%s</span>' % (BAD if nxt.is_deadline_exceeded else '#262e3a', esc(nxt.name), (' (%s)' % nxt.deadline) if nxt.deadline else '')) if nxt else '&mdash;'
        prow += '<tr><td style="padding:6px 0;border-top:1px solid #e4ded7"><a href="%s%s" style="color:#043f45">%s</a></td><td style="%s;color:%s;font-weight:600">%s</td><td style="%s">%d</td><td style="%s;color:%s">%d</td><td style="%s">%d</td><td style="%s">%s</td></tr>' % (
            base, p.get_portal_url(), esc(p.name), cell, st[1], st[0], cell, len(open_k), cell, BAD if overdue else '#262e3a', len(overdue), cell, len(done_k), cell, mile)
        overdue_names += ['%s: %s (%s)' % (esc(p.name), esc(t.name), str(t.date_deadline)[:10]) for t in overdue.sorted('date_deadline')]
        n_proj += 1; n_open_k += len(open_k); n_overdue += len(overdue)
    # The Projects card is separate from the Helpdesk one, and absent when the client has no project.
    pcard = ''
    if prow:
        ppill = ('<span style="background:#fdecee;color:%s;padding:2px 8px;border-radius:10px;font-size:12px">%d overdue</span>' % (BAD, n_overdue)) if n_overdue else ('<span style="background:#e9f3ee;color:%s;padding:2px 8px;border-radius:10px;font-size:12px">On track</span>' % OK)
        pline = '<b>%d</b> project%s &middot; <b>%d</b> open tasks' % (n_proj, 's' if n_proj > 1 else '', n_open_k)
        plate = ('<div style="color:%s;font-size:12px;margin-top:8px">Overdue: %s</div>' % (BAD, ' &middot; '.join(overdue_names))) if overdue_names else ''
        pcard = '<div style="background:#fff;border:1px solid #e4ded7;border-radius:8px;padding:16px 18px;margin-top:14px"><div style="font-size:16px;font-weight:600;margin-bottom:6px">Projects &nbsp;%s</div><div>%s</div>%s%s</div>' % (
            ppill, pline, head('Projects', ['Project', 'Status', 'Open tasks', 'Overdue', 'Done this week', 'Next milestone']) + prow + '</table>', plate)
    subject = '[Ridgebase Support] %s, weekly recap %s to %s: %d open%s' % (c, week_ago.strftime('%Y-%m-%d'), now.strftime('%Y-%m-%d'), len(open_t), (', %d past SLA' % len(late)) if late else '')
    body = '<html><body style="margin:0;padding:24px;background:#f8f7f5;font:14px/1.45 -apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#262e3a"><div style="max-width:720px;margin:0 auto"><div style="color:%s;font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.12em">Ridgebase &middot; Support</div><h1 style="font:400 26px/1.15 Palatino Linotype,Palatino,Georgia,serif;margin:2px 0 16px">%s, weekly recap</h1><div style="background:#fff;border:1px solid #e4ded7;border-radius:8px;padding:16px 18px"><div style="font-size:16px;font-weight:600;margin-bottom:6px">Helpdesk, %s to %s &nbsp;%s</div><div>%s</div>%s</div>%s<div style="color:%s;font-size:12px;margin-top:16px">Sent every Monday by Ridgebase Support &middot; <a href="%s/my/tickets" style="color:%s">All your tickets</a></div></div></body></html>' % (
        BAD, esc(c), week_ago.strftime('%Y-%m-%d'), now.strftime('%Y-%m-%d'), pill, line, table, pcard, MUTED, base, MUTED)
    env['mail.mail'].sudo().create({'subject': subject, 'body_html': body, 'email_to': to, 'auto_delete': True})
