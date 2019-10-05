#!/usr/bin/python3

import cgi, codecs, json, os, re, subprocess, sys, urllib

sys.stdout = codecs.getwriter("utf-8")(sys.stdout.detach())

print('Content-Type: text/html')
print('')

print('<style>')
print('body { margin-left: 30px }')
print('h3 { margin-left: -20px; margin-bottom: 0px }')
print('h4 { margin-left: -10px; margin-bottom: 0px; margin-top:2px }')
print('pre { margin-top: 0px; margin-bottom: 0px }')
print('</style>')

if os.environ['QUERY_STRING']:
    params =  urllib.parse.parse_qs(os.environ['QUERY_STRING'])
else:
    params = {}

logfile_path = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + "/log.txt"

thumbs = {}

if 'id' in params:
    show_id = params['id'][0]
    if not re.match(r'[\d:]+', show_id):
        print('Illegal format for id')
        exit(-1)
    max_size = 1000 * 1e6 # 1 GB
    print('<h2>Showing detail for thumbnail request %s</h2>' % show_id)
else:
    show_id = None
    max_size = 100 * 1e6 # 100 MB

log_size = os.path.getsize(logfile_path)

if log_size > max_size:
    print('Logfile is %.1f MB, only reading last %.1f MB<br>' % (log_size / 1e6, max_size / 1e6))
    
cmd = 'tail --bytes=%d "%s" | tail +2' % (max_size, logfile_path)

if show_id:
    cmd += ' | grep %s' % show_id

p = subprocess.Popen(cmd, shell=True, encoding='utf-8', stdout=subprocess.PIPE)

ids = []

num_thumbnails = 50
if 'n' in params:
    num_thumbnails = int(params['n'][0])

all_lines = []
    
for line in p.stdout:
    if show_id:
        all_lines.append(line)
    if line.strip() == "":
        continue
    tokens = line.split(None, 6)
    try:
        id = tokens[3]
    except:
        continue
    if not id in thumbs:
        thumbs[id] = {}
    try:
        thumbs[id][tokens[4]] = line
    except:
        continue
    thumbs[id]['last'] = line
    if tokens[4] == 'STARTTHUMBNAIL':
        ids.append(id)

header_footer = ""
if len(ids) > num_thumbnails:
    header_footer = '<h3>Showing most recent %d thumbnails.  <i><a href="%s?n=%d">show twice as many</a></i></h3>' % (num_thumbnails, os.environ['SCRIPT_URL'], num_thumbnails * 2)

print(header_footer)

for id in reversed(ids[-num_thumbnails:]):
    line = thumbs[id]['STARTTHUMBNAIL']
    tokens = line.split(None, 6)
    url = tokens[5]
    queryparams =  urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
    if not 'format' in queryparams:
        continue
    print('<h3>%s %sx%s %s %s</h3>' % (queryparams['format'][0], queryparams['width'][0], queryparams['height'][0], tokens[0], tokens[1].split('.')[0]))
    stats = {}

    if 'CHECKPOINTTHUMBNAIL' in thumbs[id]:
        json_str = thumbs[id]['CHECKPOINTTHUMBNAIL'].split(None, 6)[-1]
        stats = json.loads(json_str)

    if 'ENDTHUMBNAIL' in thumbs[id]:
        json_str = thumbs[id]['ENDTHUMBNAIL'].split(None, 6)[-1]
        stats = json.loads(json_str)

    request = ""
    if 'HTTP_REFERER' in stats:
        request += "<b>Referer:</b> %s " % stats['HTTP_REFERER']
    if 'REMOTE_ADDR' in stats:
        request += "<b>IP:</b> %s " % stats['REMOTE_ADDR']
    if 'HTTP_USER_AGENT' in stats:
        request += "<b>Browser:</b> %s " % stats['HTTP_USER_AGENT']
    if request:
        print(request)
        
    print('<h4>Root</h4>\n%s<br>\n' % cgi.escape(queryparams['root'][0]))
        
    if 'delegatedTo' in stats:
        print('<h4>Delegated to</h4>\n%s<br>\n' % cgi.escape(stats['delegatedTo']))

    if 'ENDTHUMBNAIL' in thumbs[id]:
        if not 'totalTimeSecs' in stats:
            continue
        print('<h4>Finished</h4>\n')
        if 'videoFrameCount' in stats:
            print('%d frames in %.1f seconds (%.1f frames rendered per second)<br>' % (stats['videoFrameCount'], stats['totalTimeSecs'], stats['videoFrameCount'] / stats['totalTimeSecs']))
        else:
            print('Took %.1f seconds<br>' % (stats['totalTimeSecs']))
        if 'frameEfficiency' in stats:
            print('Frame efficiency %.1f%%<br>' % (stats['frameEfficiency'] * 100))
            
        if 'recompute' in url:
            print('WARNING, RECOMPUTE TAG, DO NOT FOLLOW THIS LINK: %s<br>' % url)
        elif queryparams['format'][0] == 'mp4':
            print('<a href="%s"><video src="%s" autoplay loop muted style="max-height:300px"></video><br>link</a>' % (url, url))
        else:
            print('<a href="%s"><img src="%s" style="max-height:300px"><br>link</a>' % (url, cgi.escape(url)))
    else:
        pid = id.split(':')[0]
        if os.path.exists('/proc/%s' % pid):
            print('<h4>In progress</h4>\n%s<br>' % cgi.escape(url))
        else:
            print('<h4>Died before finishing</h4>\n%s<br>' % cgi.escape(url))
        if 'Need' in thumbs[id]:
            print('<code>%s</code><br>' % thumbs[id]['Need'])
        if 'FATALERROR' in stats:
            stats['FATALERROR'] = stats['FATALERROR'][0:500]
            print('<h4>Fatal error</h4>\n<pre>%s</pre>\n' % cgi.escape(stats['FATALERROR']))
        if 'CHECKPOINTTHUMBNAIL' in thumbs[id]:
            print('<h4>Last checkpoint</h4><code>%s</code><br>' % cgi.escape(thumbs[id]['CHECKPOINTTHUMBNAIL'][0:500]))
        print('<h4>Last line</h4><code>%s</code><br>' % cgi.escape(thumbs[id]['last'][0:500]))
    print('<h4>Raw stats</h4>')
    if stats:
        print('<code>%s</code><br>' % cgi.escape(json.dumps(stats)))
    print('<code>More: grep %s %s</code><br>' % (':'.join(id.split(':')[0:2]), logfile_path))
    if show_id:
        print('<h4>Full log</h4>')
        print('<pre>%s</pre><br>' % cgi.escape(''.join(all_lines)))
    else:
        print('<h4><a href="status?id=%s">Show full log</a></h4>' % id)

print(header_footer)
