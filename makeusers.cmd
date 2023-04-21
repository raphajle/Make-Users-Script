@echo off
net.exe session 1>NUL 2>NUL || (Echo Users Maker Script " Access denied " { please run as administrator }. & pause & exit /b 1)

where dsadd 1>NUL 2>NUL || (Echo Users Maker Script " Access denied " { the script must run on a server }. & pause & exit /b 1)

set ecode=0
set /p domain=Enter the domain for the new users (e.g. "canado, example, etc."): 
set /p ext=Enter extention of the domain (e.g. "edu, ht, com, etc."): 

:start
cls
set /p ou=Enter the OU for the new users (e.g. "Student,Sales, etc."): 
echo Checking if OU "%ou%" exists...

for /f %%a in ('dsquery ou -name %ou% ^| find /c /v ""') do set num_lines=%%a
if %num_lines% NEQ 0 goto getscript

echo The specified OU does not exist. Creating it...
dsadd ou "ou=%ou%,dc=%domain%,dc=%ext%"

for /f %%a in ('dsquery ou -name %ou% ^| find /c /v ""') do set num_lines=%%a
if %num_lines% NEQ 0 goto getscript

set msg=Sorry, failed to add OU "%ou%".
goto err


:getscript
cls
if "%logonscript%" EQU "" set logonscript=
set upload=N
set /p upload=Would you like to place your script in the netlogon folder [Y/N.] : 
if /i %upload% EQU Y start \\%computername%\netlogon\
cls
echo Enter the logon script (e.g. "theScript.bat")
echo.
dir "\\%computername%\netlogon\"
echo.
set /p logonscript=Live blank to skip (def. "%logonscript%"): 

if "%logonscript%" EQU "" goto mustchpwd
if "%logonscript:~-4%" EQU ".bat" set isok=yes
if "%logonscript:~-4%" EQU ".cmd" set isok=yes
if %isok% NEQ yes goto getscript


:mustchpwd
set /p mustchpwd=User must change password at next logon [Y/N] : 
if /i %mustchpwd% NEQ Y set mustchpwd=N


:getcsv
cls
echo Adding the users list...
set csvfile=auto
echo Enter the full path of the CSV file (e.g. "C:\Users\JohnDoe\Documents\newusers.csv")
echo  (csv.model. firstname, lastname, username, password)
echo NB : use "Tab" or "Shift + Tab" to autocompleate the file path
set /p csvfile=Live blank to generate users automatically : 


if EXIST %csvfile% goto method2
if "%csvfile%" NEQ "auto" goto getcsv


cls
echo Generating users...
set /p lim=Enter the number of users (e.g. "1, 10, 200"): 
set /A lim=%lim%

set pref=%ou%
set /p pref=Enter the prefix for users (e.g. "%ou%, user%ou%"): 
set /p pass=Enter the default password for users (e.g. "password"): 



set /A x=1
:method1
cls
echo Adding user %x% of %lim% to "%ou%" ...

set /a "num=%x%"
set "uid=000%num%"
set "uid=%uid:~-3%"

set cname=%ou% %x%
set username=%pref%%uid%
set password=%pass%

set msg=Sorry, failed to add user "%username%".
dsadd user "cn=%username%,ou=%ou%,dc=%domain%,dc=%ext%" -samid %username% -upn %username%@%domain%.%ext% -display "%cname%" -pwd %password% -disabled no
if /i "%logonscript%" NEQ "" dsmod user "cn=%username%,ou=%ou%,dc=%domain%,dc=%ext%" -loscr "%logonscript%"
if /i %mustchpwd% EQU Y dsmod user "cn=%username%,ou=%ou%,dc=%domain%,dc=%ext%" -mustchpwd yes
if /i %mustchpwd% EQU N dsmod user "cn=%username%,ou=%ou%,dc=%domain%,dc=%ext%" -pwdneverexpires yes
if %errorlevel% NEQ 0 goto err

set /A x=%x%+1
if %x% LEQ %lim% goto method1
goto end



:method2
for /f "tokens=1,2,3,4 delims=," %%a in (%csvfile%) do (
    set firstname=%%a
    set lastname=%%b
    set username=%%c
    set password=%%d

    set msg=Sorry, failed to add user "%username%".
    dsadd user "cn=%username%,ou=%ou%,dc=%domain%,dc=%ext%" -samid %username% -upn %username%@%domain%.%ext% -fn %firstname% -ln %lastname% -display "%firstname% %lastname%" -pwd %password% -disabled no
    if /i "%logonscript%" NEQ "" dsmod user "cn=%username%,ou=%ou%,dc=%domain%,dc=%ext%" -loscr "%logonscript%"
    if /i %mustchpwd% EQU Y dsmod user "cn=%username%,ou=%ou%,dc=%domain%,dc=%ext%" -mustchpwd yes
    if /i %mustchpwd% EQU N dsmod user "cn=%username%,ou=%ou%,dc=%domain%,dc=%ext%" -pwdneverexpires yes
    if %errorlevel% NEQ 0 goto err
)



:end
echo Done.
set /p q=Would you like to continue ? [Y/N]: 
if /I "%q%" EQU "Y" goto start
if %ecode% NEQ 0 exit /b %ecode%
exit



:err
echo %msg%
pause
set ecode=1
goto end