DATABASE sysadmin;

DROP FUNCTION IF EXISTS ifx_boot_system( VARCHAR(255) );

CREATE FUNCTION ifx_boot_system( 
                data_path VARCHAR(255) DEFAULT '$INFORMIXDIR/tmp'
                ) 
    RETURNING INTEGER
DEFINE result  INTEGER;
DEFINE tmp     BIGINT;
DEFINE server_size     VARCHAR(32);
DEFINE space_size      INTEGER;
DEFINE ifxdir          VARCHAR(255);
DEFINE json_listener   VARCHAR(64);
DEFINE os_memfree     BIGINT;
DEFINE os_cpu_count  INTEGER;
DEFINE cdr_queuemem_var  INTEGER;
DEFINE tmpstr     LVARCHAR(1024);
DEFINE tmpint     INTEGER;
DEFINE dbservname VARCHAR(128);

LET ifxdir = (SELECT env_value 
                     FROM sysmaster:sysenv 
                     WHERE env_name = "INFORMIXDIR");
--SET DEBUG FILE TO TRIM(ifxdir)||"/tmp/informix_setup.out";
SET DEBUG FILE TO "/tmp/informix_setup.out";
TRACE ON;


-- If AUTO_TUNE_SERVER_SIZE is not set the set it to medium
LET result = 
        (SELECT admin("MODIFY CONFIG PERSISTENT","AUTO_TUNE_SERVER_SIZE","MEDIUM")
	FROM sysmaster:syscfgtab 
        WHERE cf_name = "AUTO_TUNE_SERVER_SIZE"
	AND (cf_effective = "OFF" OR cf_effective IS NULL) );
IF result < 0 THEN
    LET server_size, space_size = "MEDIUM", 100;
ELSE

--- Medium is the default and error case
SELECT NVL(cf_effective , "MEDIUM"), 
       CASE UPPER(cf_effective)
             WHEN "SMALL"  THEN 50
             WHEN "LARGE"  THEN 200 
             WHEN "XLARGE" THEN 500 
             ELSE 100
       END
       INTO server_size,  space_size
       FROM sysmaster:syscfgtab 
       WHERE cf_name = "AUTO_TUNE_SERVER_SIZE";
END IF

LET tmp=0;
LET result =  admin("STORAGEPOOL ADD", data_path, 0,0,"64MB",1); 
LET result =  admin("CREATE PLOGSPACE FROM STORAGEPOOL", "plog", "22GB"); 
LET result =  admin("CREATE DBSPACE FROM STORAGEPOOL", "llog", "15GB"); 
LET result =  admin("CREATE DBSPACE FROM STORAGEPOOL", "datadbs1", "10GB", "8K"); 
LET result =  admin("CREATE DBSPACE FROM STORAGEPOOL", "datadbs2", "10GB", "8K"); 
LET result =  admin("CREATE DBSPACE FROM STORAGEPOOL", "datadbs3", "10GB", "8K"); 
LET result =  admin("CREATE DBSPACE FROM STORAGEPOOL", "datadbs4", "10GB", "8K"); 
LET result =  admin("CREATE DBSPACE FROM STORAGEPOOL", "datadbs5", "10GB", "8K"); 
LET result =  admin("CREATE TEMPDBSPACE FROM STORAGEPOOL", "tmpdbspace", "10GB", "8K"); 
{****   Set all dbspaces to grow by 10% or created new chunk use original size ****}
FOREACH SELECT  admin("MODIFY SPACE SP_SIZES", name, "200MB", 10)  AS res
          INTO result
          FROM sysmaster:sysdbstab
          WHERE bitand(flags, '0x8012')=0
          LET tmp=tmp+1;
END FOREACH
LET result =  admin("CREATE SBSPACE FROM STORAGEPOOL", "sbspace1", 
                     "100MB", 1); 
LET result =  admin("modify space sp_sizes", "sbspace1", 100, 10 );
LET result =  admin("CREATE TEMPSBSPACE FROM STORAGEPOOL", "tmpsbspace", "100MB");
LET result =  admin("MODIFY SPACE SP_SIZES", "tmpsbspace", 100, 10 );
{****   Register the default spaces  ****}
LET result =  admin("MODIFY CONFIG PERSISTENT","SBSPACENAME","sbspace1");
LET result =  admin("MODIFY CONFIG PERSISTENT","DBSPACETEMP","tmpdbspace");
LET result =  admin("MODIFY CONFIG PERSISTENT","SBSPACETEMP","tmpsbspace");




{****   Add 10 logical logs consuming the entire log space ****}
FOREACH SELECT  
admin("add log","llog",
((SUM(nfree*D.pagesize/1024)/100)::integer*100)/10 ||" KB",10,"true") AS res
    INTO result
    FROM sysmaster:syschktab C, sysmaster:sysdbstab D
    WHERE D.name='llog'
    AND   C.dbsnum=D.dbsnum
          LET tmp=tmp+1;
END FOREACH


{****   Drop all logical logs in the rootdbs but the current log ****}
FOREACH SELECT admin("drop log", number) AS res
     INTO result
     FROM sysmaster:syslogfil
     WHERE chunk = 1 AND sysmaster:bitval(flags,"0x02")==0
          LET tmp=tmp+1;
END FOREACH

FOREACH SELECT admin("onmode", "l") 
     INTO result
     FROM sysmaster:syslogfil
     WHERE chunk = 1 AND sysmaster:bitval(flags,"0x02")>0
          LET tmp=tmp+1;
END FOREACH

LET result = admin("checkpoint");

{****   Drop the current logical log in the rootdbs ****}
FOREACH SELECT admin("drop log", number)  AS res
     INTO result
     FROM sysmaster:syslogfil 
     WHERE chunk = 1
          LET tmp=tmp+1;
END FOREACH

FOREACH SELECT admin("alter plog","plog", MAX(nfree*D.pagesize/1024) )  AS res
     INTO result
     FROM sysmaster:syschktab C, sysmaster:sysdbstab D
     WHERE D.name='plog'
     AND   C.dbsnum=D.dbsnum
          LET tmp=tmp+1;
END FOREACH

LET result = admin("checkpoint");

LET result = admin("modify config persistent","AUTO_TUNE","1");
LET result = admin("modify config persistent","AUTO_READAHEAD","1");
LET result = admin("modify config persistent","AUTO_LRU_TUNING","1");
LET result = admin("modify config persistent","AUTO_AIOVPS","1");
LET result = admin("modify config persistent","AUTO_REPREPARE","1");
LET result = admin("modify config persistent","AUTO_STAT_MODE","1");
LET result = admin("modify config persistent","AUTO_CKPTS","1");
LET result = admin("modify config persistent","AUTOLOCATE","1");
LET result = admin("modify config persistent","AUTO_PLOG","1,plog");
LET result = admin("modify config persistent","AUTO_LLOG","1,llog");
LET result = admin("modify config persistent","DEF_TABLE_LOCKMODE","row");
---Ensure BAR_BSALIB_PATH is set to the default
LET result = admin("modify config persistent","BAR_BSALIB_PATH","");
LET result = 
        (SELECT admin("modify config persistent","DS_TOTAL_MEMORY","64000")
	FROM sysmaster:syscfgtab 
	WHERE cf_name matches "DS_TOTAL_MEMORY"
	AND cf_effective < 64000);
LET result = admin("modify config persistent","DS_NONPDQ_QUERY_MEM","2048");
LET result = admin("modify config persistent","DS_MAX_QUERIES","4");
LET result = admin("modify config persistent","LTAPEDEV","/dev/null");
LET result = admin("modify config persistent","TEMPTAB_NOLOG","1");
LET result = admin("modify config persistent","USTLOW_SAMPLE","1");
LET result = admin("modify config persistent","DIRECTIVES","1");
LET result = admin("modify config persistent","DUMPSHMEM","2");
LET os_memfree = (select os_mem_free/(1024*1024) FROM sysmaster:sysmachineinfo);
-- 2 GB
LET result = admin("modify config persistent","SHMADD", 2*1024*1024 );

{****   If we have less than 1GB free set it to 16MB 
        else MAX( 1/12 of what is free, 2GB) ****}


---Enable auto log rotate
UPDATE sysadmin:ph_task SET (tk_enable)=('t') WHERE tk_name = "online_log_rotate";


    RETURN result;

END FUNCTION;

--EXECUTE FUNCTION ifx_boot_system( );

