function _pure_prompt_jj_branch \
    --description 'Print jj change id/bookmark with status indicators'

    # Single jj call: ref + empty status, tab-separated
    set --local jj_info (command jj log -r @ --no-graph -T 'coalesce(bookmarks.join(","), change_id.short(8)) ++ "\t" ++ if(empty, "1", "0")' 2>/dev/null)

    if test -n "$jj_info"
        set --local parts (string split \t $jj_info)
        set --local jj_ref $parts[1]
        set --local is_empty $parts[2]

        set --local jj_branch_color (_pure_set_color $pure_color_git_branch)

        if test "$is_empty" = "1"
            echo "$jj_branch_color$jj_ref"
        else
            set --local jj_dirty_color (_pure_set_color $pure_color_git_dirty)
            echo "$jj_branch_color$jj_ref$jj_dirty_color*"
        end
    end
end
