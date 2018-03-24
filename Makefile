all: filters/difference-filter

filters/difference-filter: difference-filter.cpp
	g++ -Wall -O3 -o $@ $^

test:
	curl 'http://localhost/cgi-bin/thumbnail?root=http%3A%2F%2Fearthengine.google.org%2Ftimelapse%2Fdata%2F20130507&boundsNWSE=85.051128,-180,-85.051128,180&height=100&frameTime=0'

