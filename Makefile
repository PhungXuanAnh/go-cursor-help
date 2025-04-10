run:
	sudo -E scripts/run/cursor_linux_id_modifier.sh

run-en:
	sudo -E scripts/run/cursor_linux_id_modifier_en.sh

rebase:
	git remote add upstream https://github.com/yuaotian/go-cursor-help.git ||:
	git pull upstream master
	git rebase upstream/master
	git push origin master --force

run-cursor-ide:
	~/repo/cursor-free-vip/squashfs-root/AppRun

git-create-tag:
	scripts/create_tag.sh