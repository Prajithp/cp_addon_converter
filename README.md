cp_addon_converter
==================

This is a small perl script for converting cpanel addon domain to main domain.

Note:
- You will have to create the DB's and users manually once the conversion is complete.
Also you will have to replace the old mysql connection strings from the web scripts.

```bash
root@server1 [~]# perl convert_addon.pl 
Usage:
convert_addon.pl --addon_domain=<addon_domain_name> --main_user=<main cpanel username>  --addon_user=<new domain username> --addon_pass=<new domain password>

requird options
--addon_domain: specify the addon domain name which you want to convert
--main_user   : Usename of the addon domain
--addon_user  : new cpanel username
--addon_pass  : cpanel password

optional
-V   : print script version
-h   : print this help message and exit
```
```bash
perl convert_addon.pl --addon_domain=prajith.in --main_user=prajith --addon_user=website2 --addon_pass=test
```
