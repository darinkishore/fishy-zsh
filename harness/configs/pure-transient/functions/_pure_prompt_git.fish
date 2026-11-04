function _pure_prompt_git \
    --description 'Print git/jj repository info: branch name, dirty, upstream ahead/behind'

    set ABORT_FEATURE 2

    if set --query pure_enable_git; and test "$pure_enable_git" != true
        return
    end

    # Prefer jj if available and we're in a jj repo
    if type -q --no-functions jj; and jj root >/dev/null 2>&1
        _pure_prompt_jj_branch
        return
    end

    # Fall back to git
    if not type -q --no-functions git
        return $ABORT_FEATURE
    end

    set --local is_git_repository (command git rev-parse --is-inside-work-tree 2>/dev/null)

    if test -n "$is_git_repository"
        set --local git_prompt (_pure_prompt_git_branch)(_pure_prompt_git_dirty)(_pure_prompt_git_stash)
        set --local git_pending_commits (_pure_prompt_git_pending_commits)

        if test (_pure_string_width $git_pending_commits) -ne 0
            set --append git_prompt $git_pending_commits
        end

        echo $git_prompt
    end
end
