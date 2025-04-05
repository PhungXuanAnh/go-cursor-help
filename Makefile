run:
	sudo -E scripts/run/cursor_linux_id_modifier.sh

rebase:
	git remote add upstream https://github.com/yuaotian/go-cursor-help.git ||:
	git pull upstream master
	git rebase upstream/master
	git push origin master --force

extract-appimage:
	./Cursor-0.47.9-x86_64.AppImage --appimage-extract
