-- 双击即用：以调试模式（端口 9238）重启 ChatGPT（Codex）。
-- 内部调用仓库里的 tool/restart_target_debug.sh --yes（逻辑以脚本为准）。
-- 编译：osacompile -o ~/Desktop/"调试重启 ChatGPT（9238）.app" tool/restart_target_debug.applescript
on run
	set confirmResult to display dialog "以调试模式（端口 9238）重启 ChatGPT（Codex）？" & return & return & "会中断当前 codex 云端会话窗口；不会触碰 codex CLI。重启后调试端口保持开放，实测可反复 attach，不需要再重启。" buttons {"取消", "重启"} default button "重启" with icon caution
	if button returned of confirmResult is "重启" then
		try
			set scriptOutput to do shell script "/Users/ghost233/Ghost233Code/GhostCodexInspect/tool/restart_target_debug.sh --yes 2>&1"
			display dialog scriptOutput buttons {"好"} default button "好"
		on error errMsg
			display dialog "重启脚本失败：" & return & return & errMsg buttons {"好"} default button "好" with icon stop
		end try
	end if
end run
