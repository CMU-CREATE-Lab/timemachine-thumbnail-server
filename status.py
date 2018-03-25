#!/usr/bin/python

import cgi, json, os, subprocess, urlparse

print 'Content-Type: text/html'
print ''

print '<style>'
print 'body { margin-left: 30px }'
print 'h3 { margin-left: -20px; margin-bottom: 0px }'
print 'h4 { margin-left: -10px; margin-bottom: 0px; margin-top:2px }'
print 'pre { margin-top: 0px; margin-bottom: 0px }'
print '</style>'

logfile_path = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + "/log.txt"
#logfile_path = '/t/thumbnails.cmucreatelab.org/log.txt'

thumbs = {}

lines = open(logfile_path).readlines()
print 'Read %d lines from %s<br>' % (len(lines), logfile_path)
ids = []

for line in lines:
    if line.strip() == "":
        continue
    tokens = line.split(None, 6)
    id = tokens[3]
    if not id in thumbs:
        thumbs[id] = {}
    thumbs[id][tokens[4]] = line
    thumbs[id]['last'] = line
    if tokens[4] == 'STARTTHUMBNAIL':
        ids.append(id)
        print 'Found id %s<br>' % id

print ids[-200:]

for id in ids[-200:]:
    line = thumbs[id]['STARTTHUMBNAIL']
    tokens = line.split(None, 6)
    url = tokens[5]
    queryparams =  urlparse.parse_qs(urlparse.urlparse(url).query)
    print '<h3>Thumbnail %s %sx%s %s %s %s</h3>' % (queryparams['format'][0], queryparams['width'][0], queryparams['height'][0], tokens[0], tokens[1], id)
    stats = {}

    if 'CHECKPOINTTHUMBNAIL' in thumbs[id]:
        json_str = thumbs[id]['CHECKPOINTTHUMBNAIL'].split(None, 6)[-1]
        stats = json.loads(json_str)

    if 'ENDTHUMBNAIL' in thumbs[id]:
        json_str = thumbs[id]['ENDTHUMBNAIL'].split(None, 6)[-1]
        stats = json.loads(json_str)

    request = ""
    if 'REMOTE_ADDR' in stats:
        request += "IP: %s " % stats['REMOTE_ADDR']
    if 'HTTP_REFERER' in stats:
        request += "Referer: %s " % stats['HTTP_REFERER']
    if 'HTTP_USER_AGENT' in stats:
        request += "Browser: %s " % stats['HTTP_USER_AGENT']
    if request:
        print request
        
    print '<h4>Root</h4>\n%s<br>\n' % cgi.escape(queryparams['root'][0])
        
    if 'ENDTHUMBNAIL' in thumbs[id]:
        if not 'totalTimeSecs' in stats:
            continue
        print '<h4>Finished</h4>\n'
        if 'videoFrameCount' in stats:
            print '%d frames in %.1f seconds (%.1f frames rendered per second)<br>' % (stats['videoFrameCount'], stats['totalTimeSecs'], stats['videoFrameCount'] / stats['totalTimeSecs'])
        else:
            print 'Took %.1f seconds<br>' % (stats['totalTimeSecs'])
        if 'frameEfficiency' in stats:
            print 'Frame efficiency %.1f%%<br>' % (stats['frameEfficiency'] * 100)
            
        if 'recompute' in url:
            print 'WARNING, RECOMPUTE TAG, DO NOT FOLLOW THIS LINK: %s<br>' % url
        elif queryparams['format'][0] == 'mp4':
            print '<a href="%s"><video src="%s" autoplay=autoplay loop=loop height=300></a>' % (url, url)
        else:
            print '<a href="%s"><img src="%s" height=300></a>' % (url, cgi.escape(url))
    else:
        pid = id.split(':')[0]
        if os.path.exists('/proc/%s' % pid):
            print '<h4>In progress</h4>\n%s<br>' % cgi.escape(url)
        else:
            print '<h4>Died before finishing</h4>\n%s<br>' % cgi.escape(url)
        if 'Need' in thumbs[id]:
            print '<code>%s</code><br>' % thumbs[id]['Need']
        if 'FATALERROR' in stats:
            print '<h4>Fatal error</h4>\n<pre>%s</pre>\n' % stats['FATALERROR']
        print '<h4>Last checkpoint</h4><code>%s</code><br>' % thumbs[id]['CHECKPOINTTHUMBNAIL']
        print '<h4>Last line</h4><code>%s</code><br>' % thumbs[id]['last']
    print '<h4>Raw stats</h4><code>%s</code><br>' % stats
