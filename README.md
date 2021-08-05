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

All services have been set to work with supervisord, thus allowing for self healing auto restarts on crash
