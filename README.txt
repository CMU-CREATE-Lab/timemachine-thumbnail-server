See https://docs.google.com/document/d/1WjCOWnu9jzjdSCnjPMQ8IqfsRabOPNyIeeQa1I_uNSo/edit#

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

http://timemachine-api.cmucreatelab.org/thumbnail.jpg&root=http%3A%2F%2Fearthengine.google.org%2Ftimelapse%2Fdata%2F20130507&boundsNWSE=-8.02999,-65.51147,-13.56390,-59.90845&height=100&frameNo=28
