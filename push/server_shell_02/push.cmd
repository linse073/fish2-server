ssh -i ../id_rsa.by ubuntu@146.56.234.157 "[ ! -d server_shell_02 ] && mkdir -p server_shell_02"
scp -i ../id_rsa.by ./*.sh ubuntu@146.56.234.157:~/server_shell_02
ssh -i ../id_rsa.by ubuntu@146.56.234.157 "find . -name "*.sh" | xargs chmod a+x"
pause