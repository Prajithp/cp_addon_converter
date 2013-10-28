cp_addon_converter
==================

This is small perl script for converting cpanel addon domain to main domain

```bash
root@server1 [~]# perl convert_addon.pl 
Usage:
convert_addon.pl --addon_domain=<addon_domain_name> --main_user=<main cpanel username>  --addon_user=<new domain username> --addon_pass=<new domain password>

requird options
--addon_domain: specify the addon domain name which you want to conver
--main_user   : specify the usename of the addon domain
--addon_user  : specify the new account username
--addon_pass  : specify the password for new account

optional
-V   : print script version
-h   : print this help message and exit
```
```bash
perl convert_addon.pl --addon_domain=prajith.in --main_user=prajith --addon_user=website2 --addon_pass=test
```
