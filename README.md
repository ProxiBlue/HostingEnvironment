# Base jelastic environment suited for Magento 2 

The JPS package deploys Magento that initially contains 

* 1 application server 
* 1 database container
* 1 redis no sql container for sessions
* 1 elastic search container

### Specifics

Layer                |     Server    | Number of CTs <br/> by default | Cloudlets per CT <br/> (reserved/dynamic) | Options
-------------------- | --------------| :----------------------------: | :---------------------------------------: | :-----:
CP                   |    NGINX      |       1                        |           20 / 74                          | -
DB                   |    MarianDB   |       7                        |           20 / 74                          | -
Elasticsearch        |    ES 7.9.3   |       1                        |           1 / 16                          | -
redis                |    6.0.6      |       1                        |           1 / 4                           | -

**PHP Engine**: PHP 7.4<br/>
**MariaDB Database**: 10.3.16<br/>
**NGINX**: 1.18.0

To become root on any environment: ```su root```

All services have been set to work with supervisord, thus allowing for self healing auto restarts on crash

### POST Deploy tasks

* stop entire environment
* start entire environment

This allows for all services to be started as not all do after initial deploy work with supervisord initially

* Bind domain
* open port 80/443 on app server firewall
* install lets encrypt plugin via environment GUI

### Services / Tools Installed:

## Monit

* Set port 2812 on app server to specific set of IP as security
* access on base_url:2812
* username/pass displayed on env create

## NGINX Amplify

* Amplify ID would have been set upon env creation to link to amplify data gathering

## awscliv2

CLI client installed to facilitate backups to S3

## GOACCESS

BASE_URL/site_report.html
username/password was exported when env was created
a file must exist in site root: ```go_access_exclude_list.txt```

this lists all urls to be ignored

example:

```
/media
/static
/nginx_status
```

## maldetect-1.6.4

Open Source Malware detection cli

## Baler

* https://github.com/magento/baler