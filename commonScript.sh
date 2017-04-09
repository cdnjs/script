#!/usr/bin/env bash

function print-log() {
    echo "$@"
}

function run() {
    print-log "$(date), pwd: $(pwd), $@"
    nice -n 20 "$@"
}

function reset() {
    if git diff --exit-code > /dev/null; then
        print-log "no diff found, so do not reset!"
    else
        print-log "diff found, so reset!"
        run git reset --hard
    fi
}

function fix() {
    find "${1}" -type d -exec chmod 755 {} \; || sudo chown peter:peter -R "${1}"
    find "${1}" -type f -exec chmod 644 {} \;
}

function check() {
    oldVer="$(git diff --color=never "${1}/package.json" | command grep '^\-  "version"' | awk -F'"' '{print $4}')"
    newVer="$(git diff --color=never "${1}/package.json" | command grep '^\+  "version"' | awk -F'"' '{print $4}')"
    diffCount="$(git diff --color=never "${1}/package.json" | command grep -v '^\-\-\-' | command grep -c '^\- ')"
    if [ "${diffCount}" -gt 1 ]; then
        echo "Diff count > 1, should manually check it."
        git diff "${1}/package.json"
    elif [ -z "${oldVer}" ] || [ -z "${newVer}" ]; then
        echo "Version diff not found"
    else
        rm -rf /run/shm/cdnjsCheck/*
        tempD="/run/shm/cdnjsCheck/$(date --iso-8601)"
        mkdir -p "${tempD}"
        (
            cd "${1}/${oldVer}"
            find . | sort | command grep -v '.bot_cant_auto_add\|\.map$\|\.ts$\|\.md$' > "${tempD}/${1}_${oldVer}_fileList"
        ) &
        (
            cd "${1}/${newVer}"
            find . | sort | command grep -v '.bot_cant_auto_add\|\.map$\|\.ts$\|\.md$' > "${tempD}/${1}_${newVer}_fileList"
        ) &
        wait
        diff "${tempD}/${1}_${oldVer}_fileList" "${tempD}/${1}_${newVer}_fileList"
        ls "${1}/"
        echo -n "Wanna add ${1}? (old: ${oldVer}, new: ${newVer}) "
        read add
        if [ "${add}" = "y" ] || [ "${add}" = "Y" ]; then
            fix "${1}/${newVer}"
            cdnjs-add "${1}" "${newVer}"
        elif [ "${add}" = "b" ] || [ "${add}" = "beta" ]; then
            git checkout "${1}/package.json"
            fix "${1}/${newVer}"
            cdnjs-add "${1}" "${newVer}"
        elif [ "${add}" = "m" ] || [ "${add}" = "minify" ]; then
            fix "${1}/${newVer}"
            minify "${1}/${newVer}"
            cdnjs-add "${1}" "${newVer}"
        fi
    fi
}

function autoadd() {
    print-log "start to auto add process"
    cd "${HOME}/repos/cdnjs/cdnjs/ajax/libs/"
    for lib in $(git status ./ -uno | command grep -v '\.\.' | command grep --color=never package.json | awk '{print $2}' | awk -F'/' '{print $1}')
    do
        print-log "Found ${lib}"
        oldVer="$(git diff "${lib}/package.json" | command grep '^\-  "version"' | awk -F'"' '{print $4}')"
        newVer="$(git diff "${lib}/package.json" | command grep '^\+  "version"' | awk -F'"' '{print $4}')"
        if ! git status "${lib}/$newVer" | grep -q "${lib}/$newVer/"; then
            print-log "${lib} ${newVer} invalid!"
            continue
        fi
        diffCount="$(git diff "${lib}/package.json" | command grep -v '^\-\-\-' | command grep -c '^\- ')"
        if [ "${diffCount}" -eq 1 ] && [ ! -z "${oldVer}" ] && [ ! -z "${newVer}" ]; then
            print-log "found ver ${oldVer} -> ${newVer}"
            if [[ -f "${lib}/${newVer}/.bot_cant_auto_add" ]]; then
                echo "Found ${lib}/${newVer}/.bot_cant_auto_add, pass ..."
                continue
            fi
            tempD="/run/shm/cdnjsCheck/$(date --iso-8601)"
            mkdir -p "${tempD}"
            (
                cd "${HOME}/repos/cdnjs/cdnjs/ajax/libs/${lib}/${oldVer}"
                find . | sort | command grep -v '.bot_cant_auto_add\|\.map$\|\.ts$\|\.md$' > "${tempD}/${lib}_${oldVer}_fileList"
            ) &
            (
                cd "${HOME}/repos/cdnjs/cdnjs/ajax/libs/${lib}/${newVer}"
                find . -type f -exec chmod -x {} \;
                find . | sort | command grep -v '.bot_cant_auto_add\|\.map$\|\.ts$\|\.md$' > "${tempD}/${lib}_${newVer}_fileList"
            ) &
            wait
            if [ ! -e "${lib}/.donotoptimizepng" ] && test "$(find "${lib}/${newVer}" -name "*.png")" ; then
                find "${lib}/${newVer}" -name "*.png" | xargs -n 1 -P 7 zopflipng-f
            fi
            if test "$(find "${lib}/${newVer}" -name "*.jpeg" -o -name "*.jpg")" ; then
                find "${lib}/${newVer}" -name "*.jpeg" -o -name "*.jpg" | xargs -n 1 -P 7 jpegoptim
            fi
            oldmd5="$(md5sum "${tempD}/${lib}_${oldVer}_fileList" | cut -d ' ' -f 1)"
            newmd5="$(md5sum "${tempD}/${lib}_${newVer}_fileList" | cut -d ' ' -f 1)"
            if [ "${oldmd5}" = "${newmd5}" ]; then
                cdnjs-add "${lib}" "${newVer}"
            else
                rsync -a --delete "${lib}/${newVer}/" "${tempD}/${lib}_${newVer}_x/"
                (
                    cd "${tempD}/${lib}_${newVer}_x/"
                    ~/repos/cdnjs/web-minify-helper/minify.sh
                    find . | sort | command grep -v 'bot_cant_auto_add\|\.map$\|\.ts$\|\.md$' > "${tempD}/${lib}_${newVer}_x_fileList"
                )
                tmpmd5="$(md5sum "${tempD}/${lib}_${newVer}_x_fileList" | cut -d ' ' -f 1)"
                if [ "${oldmd5}" = "${tmpmd5}" ]; then
                    rsync -av "${tempD}/${lib}_${newVer}_x/" "${lib}/${newVer}/"
                    cdnjs-add "${lib}" "${newVer}"
                else
                    print-log "${lib} ${newVer} can not be automatically added"
                    touch "${lib}/${newVer}/.bot_cant_auto_add"
                fi
            fi
        fi
    done
    reset
    for lib in $(git status ./ | command grep '\/$' | awk -F '/' '{ print $1 }' | uniq | command grep -v 'aframe')
    do
        print-log "Found ${lib}"
        test "$(grep '"version": ' "${lib}/package.json")" || return 1
        oldVer="$(grep '"version": ' "${lib}/package.json" | awk -F'"' '{print $4}')"
        for newVer in $(git status "${lib}" | command grep '\/$' | awk -F '/' '{ print $2 }' | tac)
        do
            print-log "found ver ${newVer} (origin ${oldVer})"
            if [[ -f "${lib}/${newVer}/.bot_cant_auto_add" ]]; then
                echo "Found ${lib}/${newVer}/.bot_cant_auto_add, pass ..."
                continue
            fi
            tempD="/run/shm/cdnjsCheck/$(date --iso-8601)"
            mkdir -p "${tempD}"
            (
                cd "${HOME}/repos/cdnjs/cdnjs/ajax/libs/${lib}/${oldVer}"
                find . | sort | command grep -v '.bot_cant_auto_add\|\.map$\|\.ts$\|\.md$' > "${tempD}/${lib}_${oldVer}_fileList"
            ) &
            (
                cd "${HOME}/repos/cdnjs/cdnjs/ajax/libs/${lib}/${newVer}"
                find . -type f -exec chmod -x {} \;
                find . | sort | command grep -v '.bot_cant_auto_add\|\.map$\|\.ts$\|\.md$' > "${tempD}/${lib}_${newVer}_fileList"
            ) &
            wait
            if [ ! -e "${lib}/.donotoptimizepng" ] && test "$(find "${lib}/${newVer}" -name "*.png")" ; then
                find "${lib}/${newVer}" -name "*.png" | xargs -n 1 -P 7 zopflipng-f
            fi
            if test "$(find "${lib}/${newVer}" -name "*.jpeg" -o -name "*.jpg")" ; then
                find "${lib}/${newVer}" -name "*.jpeg" -o -name "*.jpg" | xargs -n 1 -P 7 jpegoptim
            fi
            oldmd5="$(md5sum "${tempD}/${lib}_${oldVer}_fileList" | cut -d ' ' -f 1)"
            newmd5="$(md5sum "${tempD}/${lib}_${newVer}_fileList" | cut -d ' ' -f 1)"
            if [ "${oldmd5}" = "${newmd5}" ]; then
                cdnjs-add-no-package-json "${lib}" "${newVer}"
            else
                rsync -a --delete "${lib}/${newVer}/" "${tempD}/${lib}_${newVer}_x/"
                (
                    cd "${tempD}/${lib}_${newVer}_x/"
                    ~/repos/cdnjs/web-minify-helper/minify.sh
                    find . | sort | command grep -v '.bot_cant_auto_add\|\.map$\|\.ts$\|\.md$' > "${tempD}/${lib}_${newVer}_x_fileList"
                )
                tmpmd5="$(md5sum "${tempD}/${lib}_${newVer}_x_fileList" | cut -d ' ' -f 1)"
                if [ "${oldmd5}" = "${tmpmd5}" ]; then
                    rsync -av "${tempD}/${lib}_${newVer}_x/" "${lib}/${newVer}/"
                    cdnjs-add-no-package-json "${lib}" "${newVer}"
                else
                    print-log "${lib} ${newVer} can not be automatically added"
                    touch "${lib}/${newVer}/.bot_cant_auto_add"
                fi
            fi
        done
    done
}

function cdnjs-add() {
    if [ "${2}" = "old" ]; then
        run git add "${1}"
        run git reset "${1}/package.json"
        run git commit -m "Add old versions of ${1}"
    else
        local currentVer="$(awk '{ if ("\"version\":" == $1) print $2}' "${1}/package.json"  | awk -F '"' '{print $2}')"
        if [ "${currentVer}" = "${2}" ]; then
            run git add "${1}/package.json"
        fi
        cdnjs-add-no-package-json "${1}" "${2}"
    fi
}

function cdnjs-add-no-package-json() {
    run git add "${1}/${2}"
    run git commit -m "Add ${1} v${2}"
}
