#! /bin/bash  
#MySQL running����ַ����������ݿ�汾��������ʱstatus��ʾ����Ϣȷ��  
/sbin/service mysql status | grep "MySQL running" > /dev/null  
  
if [ $? -eq 0 ]  
then  
        #״̬�������3306�˿��Ƿ���������  
        netstat -ntp | grep 3306 > /dev/null  
        if [ $? -ne 0 ]  
        then  
                /sbin/service mysql restart  
                sleep 3  
                /sbin/service mysql status | grep " MySQL running" > /dev/null  
				
                if [ $? -ne 0 ]  
                then  
                        echo "mysql service has stoped ,Automatic startup failure, please start it manually!" | mail -s "mysql is not running" 410358630@qq.com  
                 fi  
  
        fi  
else  
        /sbin/service mysql start  
        sleep 2;  
        /sbin/service mysql status | grep "MySQL running" > /dev/null  
        if [ $? -ne 0 ]  
        then  
                echo "mysql service has stoped ,Automatic startup failure, please start it manually!" | mail -s "mysql is not running" 410358630@qq.com  
        fi  
fi  