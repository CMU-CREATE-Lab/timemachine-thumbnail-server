#!/usr/bin/python

import cgi, json, os, subprocess, urlparse

print 'Content-Type: text/html'
print ''

print '<style>'
print 'body { margin-left: 20px }'
print 'h3 { margin-left: -10px; margin-bottom: 0px }'
print '</style>'

logfile_path = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + "/log.txt"
#logfile_path = '/t/thumbnails.cmucreatelab.org/log.txt'
#cmd = "egrep ' (STARTTHUMBNAIL|ENDTHUMBNAIL|Need to compute) ' %s" % logfile_path

thumbs = {}
last_line = {}

#lines = subprocess.check_output(cmd, shell=True).split('\n')
lines = open(logfile_path).readlines()
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

for id in ids[-200:]:
    line = thumbs[id]['STARTTHUMBNAIL']
    tokens = line.split(None, 6)
    url = tokens[5]
    queryparams =  urlparse.parse_qs(urlparse.urlparse(url).query)
    print '<h3>Thumbnail %s %sx%s %s %s %s</h3>' % (queryparams['format'][0], queryparams['width'][0], queryparams['height'][0], tokens[0], tokens[1], id)
    print 'Root=%s<br>' % cgi.escape(queryparams['root'][0])
    if 'ENDTHUMBNAIL' in thumbs[id]:
        json_str = thumbs[id]['ENDTHUMBNAIL'].split(None, 6)[-1]
        stats = json.loads(json_str)
        if not 'totalTimeSecs' in stats:
            continue
        if 'videoFrameCount' in stats:
            print 'Finished %d frames in %.1f seconds (%.1f frames rendered per second)<br>' % (stats['videoFrameCount'], stats['totalTimeSecs'], stats['videoFrameCount'] / stats['totalTimeSecs'])
        else:
            print 'Finished in %.1f seconds<br>' % (stats['totalTimeSecs'])
        if 'frameEfficiency' in stats:
            print 'Frame efficiency %.1f%%<br>' % (stats['frameEfficiency'] * 100)
            
        if 'recompute' in url:
            print 'WARNING, RECOMPUTE TAG, DO NOT FOLLOW THIS LINK: %s<br>' % url
        elif queryparams['format'][0] == 'mp4':
            print '<a href="%s"><video src="%s" autoplay=autoplay loop=loop height=300></a>' % (url, url)
        else:
            print '<a href="%s"><img src="%s" height=300></a>' % (url, cgi.escape(url))
        print '<pre>%s</pre><br>' % stats
    else:
        pid = id.split(':')[0]
        if os.path.exists('/proc/%s' % pid):
            print 'In progress:<br>\n%s' % cgi.escape(url)
        else:
            print 'Died before finishing:<br>\n%s' % cgi.escape(url)
        if 'Need' in thumbs[id]:
            print '<pre>%s</pre><br>' % thumbs[id]['Need']
        print 'Last line:<pre>%s</pre>' % thumbs[id]['last']
            

    

