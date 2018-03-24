#!/usr/bin/python

import json, os, subprocess

print 'Content-Type: text/html'
print ''

#logfile_path = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + "/log.txt"
logfile_path = '/t/thumbnails.cmucreatelab.org/log.txt'
cmd = "egrep ' (STARTTHUMBNAIL|ENDTHUMBNAIL) ' %s" % logfile_path

thumbs = {}

lines = subprocess.check_output(cmd, shell=True).split('\n')

for line in lines[-200:]:
    if line.strip() == "":
        continue
    tokens = line.split(None, 6)
    if not tokens[3] in thumbs:
        thumbs[tokens[3]] = {}
    thumbs[tokens[3]][tokens[4]] = line

for line in lines[-100:]:
    if line.strip() == "":
        continue
    tokens = line.split(None, 6)
    if tokens[4] == 'STARTTHUMBNAIL':
        print '<h3>Thumbnail %s %s %s</h3>' % (tokens[0], tokens[1], tokens[3])
        if 'ENDTHUMBNAIL' in thumbs[tokens[3]]:
            json_str = thumbs[tokens[3]]['ENDTHUMBNAIL'].split(None, 6)[-1]
            stats = json.loads(json_str)
            if not 'totalTimeSecs' in stats:
                continue
            if 'videoFrameCount' in stats:
                print 'Finished %d frames in %.1f seconds (%.1f frames rendered per second)<br>' % (stats['videoFrameCount'], stats['totalTimeSecs'], stats['videoFrameCount'] / stats['totalTimeSecs'])
            else:
                print 'Finished in %.1f seconds<br>' % (stats['totalTimeSecs'])
            if 'frameEfficiency' in stats:
                print 'Frame efficiency %.1f%%<br>' % (stats['frameEfficiency'] * 100)

            url = tokens[5]
            if 'recompute' in url:
                print 'WARNING, RECOMPUTE TAG, DO NOT FOLLOW THIS LINK: %s<br>' % url
            elif 'videoFrameCount' in stats and stats['videoFrameCount'] > 1:
                print '<a href="%s"><video src="%s" autoplay=autoplay loop=loop height=300></a>' % (url, url)
            else:
                print '<a href="%s"><img src="%s" height=300></a>' % (url, url)
            print '<pre>%s</pre><br>' % stats
        else:
            print 'Unfinished<br>\n%s' % tokens[5]
            
            
            

    

