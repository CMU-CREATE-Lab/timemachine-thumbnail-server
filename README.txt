For API documentation, see "Thumbnail Service API" at https://docs.google.com/document/d/1WjCOWnu9jzjdSCnjPMQ8IqfsRabOPNyIeeQa1I_uNSo/edit#

To install:
- Edit cache_dir and ffmpeg_path in thumbnail-server.rb
- Set up as a cgi script for your webserver


To run on mac, consider symlinking from /Library/WebServer/CGI-Executables/ and changing

<Directory "/Library/WebServer/CGI-Executables">
    AllowOverride None
    Options None

to

<Directory "/Library/WebServer/CGI-Executables">
    AllowOverride None
    Options FollowSymLinks

in /etc/apache2/httpd.conf

and then
sudo apachectl restart
