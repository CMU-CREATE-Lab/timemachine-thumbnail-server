#!/usr/bin/env python3

import codecs, json, os, re, sys, urllib.parse, urllib.request, html, time

sys.stdout = codecs.getwriter("utf-8")(sys.stdout.detach())

print('Content-Type: text/html')
print('')

print('<style>')
print('body { margin-left: 30px }')
print('h3 { margin-left: -20px; margin-bottom: 0px }')
print('h4 { margin-left: -10px; margin-bottom: 0px; margin-top:2px }')
print('pre { margin-top: 0px; margin-bottom: 0px }')
print('.worker { color: #555; font-weight: normal; font-size: 80% }')
print('</style>')

if 'QUERY_STRING' in os.environ:
    params =  urllib.parse.parse_qs(os.environ['QUERY_STRING'])
else:
    params = {}

# Unified log source: query Loki so /status shows every worker, not just the one
# this request happened to land on. Loki aggregates all pods' stdout (promtail);
# see lab_kubernetes observability. Single-tenant, so no auth header is needed.
# There is intentionally no local-file fallback: /status is a debugging view, and
# if Loki is down we say so rather than show a misleading single-worker picture.
LOKI_URL = os.environ.get('LOKI_URL', 'http://loki.observability.svc.cluster.local:3100')
LOKI_NAMESPACE = os.environ.get('LOKI_NAMESPACE', 'thumbnails')
MY_POD = os.environ.get('POD_NAME')

thumbs = {}

if 'id' in params:
    show_id = params['id'][0]
    if not re.match(r'^[\d:]+$', show_id):
        print('Illegal format for id')
        exit(-1)
    lookback_secs = 7 * 24 * 3600   # a specific request may be older
    print('<h2>Showing detail for thumbnail request %s</h2>' % html.escape(show_id))
else:
    show_id = None
    lookback_secs = 24 * 3600

num_thumbnails = 50
if 'n' in params:
    num_thumbnails = int(params['n'][0])

# --- Fetch log lines as (sort_key, line, worker) -----------------------------

def fetch_from_loki():
    # All vlog lines contain the literal "THUMB" (the 3rd field); this also
    # excludes Apache's own access/error lines that share the container stdout.
    query = '{namespace="%s"} |= "THUMB"' % LOKI_NAMESPACE
    if show_id:
        query += ' |= "%s"' % show_id   # show_id is validated to [\d:]+ above
    end_ns = time.time_ns()
    start_ns = end_ns - lookback_secs * 1_000_000_000
    qs = urllib.parse.urlencode({'query': query, 'start': start_ns, 'end': end_ns,
                                 'limit': 5000, 'direction': 'backward'})
    url = '%s/loki/api/v1/query_range?%s' % (LOKI_URL, qs)
    with urllib.request.urlopen(url, timeout=10) as resp:
        data = json.load(resp)
    out = []
    for stream in data['data']['result']:
        worker = stream['stream'].get('pod', '?')
        for ts, line in stream['values']:
            if not line.endswith('\n'):
                line += '\n'
            out.append((int(ts), line, worker))
    out.sort(key=lambda x: x[0])   # Loki returns newest-first; parse chronologically
    return out

try:
    lines = fetch_from_loki()
except Exception as e:
    print('<h3 style="background-color:#ff5555">Unified log (Loki) unavailable</h3>')
    print('<p>Could not query Loki at <code>%s</code>:</p>' % html.escape(LOKI_URL))
    print('<pre>%s</pre>' % html.escape(str(e)))
    print('<p>/status reads the cluster-wide log from Loki. If the observability '
          'stack is down, check <code>kubectl -n observability get pods</code> '
          'or Grafana, then retry.</p>')
    sys.exit(0)

# --- Parse (same positional format as the vlog line) -------------------------

ids = []
all_lines = []

for sort_key, line, worker in lines:
    if show_id:
        all_lines.append(line)
    if line.strip() == "":
        continue
    tokens = line.split(None, 6)
    try:
        id = ':'.join(tokens[3].split(':')[:2])
    except:
        continue
    if not id in thumbs:
        thumbs[id] = {}
    try:
        thumbs[id][tokens[4]] = line
    except:
        continue
    thumbs[id]['last'] = line
    thumbs[id]['worker'] = worker
    if tokens[4] == 'STARTTHUMBNAIL':
        ids.append(id)

header_footer = ""
if len(ids) > num_thumbnails:
    header_footer = '<h3>Showing most recent %d thumbnails.  <i><a href="%s?n=%d">show twice as many</a></i></h3>' % (num_thumbnails, os.environ.get('SCRIPT_URL', 'status'), num_thumbnails * 2)

print(header_footer)

def show_thumbnail(id):
    line = thumbs[id]['STARTTHUMBNAIL']
    tokens = line.split(None, 6)
    url = tokens[5]
    worker = thumbs[id].get('worker', '?')
    queryparams =  urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
    if not 'format' in queryparams:
        return

    stats = {}

    if 'CHECKPOINTTHUMBNAIL' in thumbs[id]:
        json_str = thumbs[id]['CHECKPOINTTHUMBNAIL'].split(None, 6)[-1]
        stats = json.loads(json_str)

    if 'ENDTHUMBNAIL' in thumbs[id]:
        json_str = thumbs[id]['ENDTHUMBNAIL'].split(None, 6)[-1]
        stats = json.loads(json_str)

    # Compute completion status
    completion_status_msg = []

    if 'ENDTHUMBNAIL' in thumbs[id]:
        if not 'totalTimeSecs' in stats:
            return
        completion_status_msg.append('<h4>Finished</h4>')
        completion_status = 'Finished'
        completion_color = '#55ff55'

        if 'videoFrameCount' in stats:
            completion_status_msg.append('%d frames in %.1f seconds (%.1f frames rendered per second)<br>' %
                                         (stats['videoFrameCount'], stats['totalTimeSecs'], stats['videoFrameCount'] / stats['totalTimeSecs']))
        else:
            completion_status_msg.append('Took %.1f seconds<br>' % (stats['totalTimeSecs']))
        if 'frameEfficiency' in stats:
            completion_status_msg.append('Frame efficiency %.1f%%<br>' % (stats['frameEfficiency'] * 100))
        if 'recompute' in url:
            completion_status_msg.append('WARNING, RECOMPUTE TAG, DO NOT FOLLOW THIS LINK: %s<br>' % url)
        elif 'asJson' in url:
            completion_status_msg.append('<a href="%s">json link</a><br>' % url)
        elif queryparams['format'][0] == 'zip':
            pass
        elif queryparams['format'][0] == 'mp4':
            completion_status_msg.append('<a href="%s"><video src="%s" autoplay loop muted style="max-height:300px"></video><br>link</a><br>' % (url, url))
        else:
            completion_status_msg.append('<a href="%s"><img src="%s" style="max-height:300px"><br>link</a><br>' % (url, html.escape(url)))
    else:
        pid = id.split(':')[0]
        if 'FATALERROR' in stats:
            completion_status = 'Failed'
            completion_color = '#ff5555'
            completion_status_msg.append('%s<br>' % html.escape(url))
            stats['FATALERROR'] = stats['FATALERROR'][0:1000]
            completion_status_msg.append('<h4>Fatal error</h4>\n<pre>%s</pre>\n' % html.escape(stats['FATALERROR']))
        else:
            completion_status = 'In progress'
            completion_color = '#ffff55'
            completion_status_msg.append('%s<br>' % html.escape(url))
            # The /proc liveness hint is only meaningful when the request ran on
            # *this* pod; across workers we can't see a remote pid.
            if MY_POD and worker == MY_POD and not os.path.exists('/proc/%s' % pid):
                completion_status_msg.append('(pid %s on this worker seems not to exist; maybe done now?)<br>' % pid)

        if 'Need' in thumbs[id]:
            completion_status_msg.append('<code>%s</code><br>' % thumbs[id]['Need'])

        if 'CHECKPOINTTHUMBNAIL' in thumbs[id]:
            completion_status_msg.append('<h4>Last checkpoint</h4><code>%s</code><br>' % html.escape(thumbs[id]['CHECKPOINTTHUMBNAIL'][0:500]))
        completion_status_msg.append('<h4>Last line</h4><code>%s</code><br>' % html.escape(thumbs[id]['last'][0:500]))

    print('<h3 style="background-color:%s">%s <a href="status?id=%s">thumbnail %s</a> %s %s <span class="worker">worker %s</span></h3>' %
          (completion_color, completion_status, id, id, tokens[0], tokens[1].split('.')[0], html.escape(worker)))

    print('%s %s x %s' % (queryparams['format'][0], queryparams.get('width', ['?'])[0], queryparams.get('height', ['?'])[0]))
    if 'videoFrameCount' in stats:
        print(' x %s frames' % stats['videoFrameCount'])

    print('\n'.join(completion_status_msg))

    request = ""

    if 'HTTP_REFERER' in stats:
        request += "<b>Referer:</b> %s " % stats['HTTP_REFERER']
    if 'REMOTE_ADDR' in stats:
        request += "<b>IP:</b> %s " % stats['REMOTE_ADDR']
    if 'HTTP_USER_AGENT' in stats:
        request += "<b>Browser:</b> %s " % stats['HTTP_USER_AGENT']
    if request:
        print(request)

    print('<h4>Root</h4>\n%s<br>\n' % html.escape(queryparams.get('root', [''])[0]))

    print('<h4>Worker</h4>\n%s<br>\n' % html.escape(worker))

    print('<h4>Raw stats</h4>')
    if stats:
        print('<code>%s</code><br>' % html.escape(json.dumps(stats)))
    print('<code>More: in Grafana Explore &rarr; Loki: {namespace=&quot;%s&quot;} |= &quot;%s&quot;</code><br>' % (html.escape(LOKI_NAMESPACE), html.escape(id)))
    if show_id:
        print('<h4>Full log</h4>')
        print('<pre>%s</pre><br>' % html.escape(''.join(all_lines)))


# Render each thumbnail; never let one malformed log entry blank the whole page.
for id in reversed(ids[-num_thumbnails:]):
    try:
        show_thumbnail(id)
    except Exception as e:
        print('<p style="color:#a00">(could not render thumbnail %s: %s)</p>'
              % (html.escape(str(id)), html.escape(str(e))))

print(header_footer)
