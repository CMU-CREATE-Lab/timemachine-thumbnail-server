#!/usr/bin/python3

import cgi, codecs, json, os, subprocess, sys, urllib

sys.stdout = codecs.getwriter("utf-8")(sys.stdout.detach())

print('Content-Type: application/json')
print('')

logfile_path = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + "/log.txt"
#logfile_path = '/t/thumbnails.cmucreatelab.org/log.txt'

thumbs = {}

log = open(logfile_path, encoding='utf-8')
log.seek(0, os.SEEK_END)
size = log.tell()
max_size = 100000000
if size > max_size:
    pos = size - max_size
    log.seek(pos)
    # Skip the first line since it might be partial
    lines = log.readlines()[1:]
else:
    log.seek(0)
    lines = log.readlines()

ids = []

if os.environ['QUERY_STRING']:
    params =  urllib.parse.parse_qs(os.environ['QUERY_STRING'])
else:
    params = {}

num_thumbnails = 50
if 'n' in params:
    num_thumbnails = int(params['n'][0])
    
for line in lines:
    if line.strip() == "":
        continue
    tokens = line.split(None, 6)
    try:
        id = tokens[3]
    except:
        continue
    if not id in thumbs:
        thumbs[id] = {}
    thumbs[id][tokens[4]] = line
    thumbs[id]['last'] = line
    if tokens[4] == 'STARTTHUMBNAIL':
        ids.append(id)

root_prefix = 'https://tiles.cmucreatelab.org/ecam/timemachines/'
site_names = {
    'clairton1': 'Clairton',
    'braddock1': 'Edgar Thomson North',
    'walnuttowers2': 'Edgar Thomson West',
    'dravosburg2': 'Irvin',
    'heinz': 'North Shore',
    'trimont1': 'Downtown',
    'walnuttowers1': 'Mon Valley',
    'oakland':'Oakland',
    'westmifflin1': 'Edgar Thomson South'
    }

results = []

for id in reversed(ids):
    line = thumbs[id]['STARTTHUMBNAIL']
    tokens = line.split(None, 6)
    created_at = tokens[0] + ' ' + tokens[1]
    url = tokens[5]
    queryparams =  urllib.parse.parse_qs(urllib.parse.urlparse(url).query, keep_blank_values=True)
    if not 'format' in queryparams:
        continue
    if 'recompute' in queryparams:
        continue
    if 'preview' in queryparams:
        continue
    root = cgi.escape(queryparams['root'][0])
    if root[:len(root_prefix)] != root_prefix:
        continue
    format = queryparams['format'][0]
    if format != 'mp4' and format != 'gif':
        continue
    if not 'ENDTHUMBNAIL' in thumbs[id]:
        continue
    if 'CHECKPOINTTHUMBNAIL' in thumbs[id]:
        json_str = thumbs[id]['CHECKPOINTTHUMBNAIL'].split(None, 6)[-1]
        stats = json.loads(json_str)
    if 'ENDTHUMBNAIL' in thumbs[id]:
        json_str = thumbs[id]['ENDTHUMBNAIL'].split(None, 6)[-1]
        stats = json.loads(json_str)
    if not 'totalTimeSecs' in stats:
        continue
    site = root[len(root_prefix):].split('/')[0]
    if site in site_names:
        site = site_names[site]
    date = root[len(root_prefix):].split('/')[1].split('.')[0]
    results.append({
        'site':site,
        'url':url,
        'date':date,
        'format':format,
        'startFrame':int(queryparams['startFrame'][0]),
        'nframes':int(queryparams['nframes'][0]),
        'created':created_at
    })

results.sort(key=lambda r: '%s_%08d' % (r['date'], r['startFrame']))

print(json.dumps(list(reversed(results))))

