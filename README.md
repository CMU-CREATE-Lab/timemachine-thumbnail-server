For API documentation, see "Thumbnail Service API" at https://docs.google.com/document/d/1NUT2UiNOPcni0WJ2PnMHl7VqBiWWw5R3jOfwqjw6_jk/edit#heading=h.1totuqfbycgg

To install:
- Edit cache_dir and ffmpeg_path in thumbnail-server.rb
- Set up as a cgi script for your webserver

Developing on a Mac?  Look at apache-config-examples/osx-rsargent.conf
and follow the comments at the top of that file to customize and install.

sudo ln -s ~/projects/timemachine/tmca/thumbnail-server/apache2-osx.conf /etc/apache2/other/thumbnail-server.conf
and then
sudo apachectl graceful


#To run on mac, consider symlinking from /Library/WebServer/CGI-Executables/ and changing
#
#<Directory "/Library/WebServer/CGI-Executables">
#    AllowOverride None
#    Options None
#
#to
#
#<Directory "/Library/WebServer/CGI-Executables">
#    AllowOverride None
#    Options FollowSymLinks
#
#in /etc/apache2/httpd.conf
#
#and then
#sudo apachectl restart
