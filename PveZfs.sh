#!/bin/bash
# ==============================================================================
# ZFS 智能存储池自动检测、物理修复与 RAID 重构工具 (PVE 高级版)
# ==============================================================================
# 限制与安全说明:
# 1. 必须以 root 权限运行，否则无法执行 zpool 和 lsblk 相关操作。
# 2. 系统主盘 (含有根分区 / 的物理盘) 在任何模式下都会被严格锁定，禁止对其执行 ZFS 操作，防止误格式化系统。
# 3. 强烈推荐使用 /dev/disk/by-id/ 路径，本脚本会优先提取该路径，防止因重启导致盘符颠倒 (/dev/sdX 变化)。
# 4. 手动强制模式允许选择已存在分区或 LVM 卷的磁盘，但会进行二次强警告确认，需要用户手动输入 "YES" 以确认强制格式化并替换。

# 终端颜色与格式定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # 重置颜色

# 状态指示器
OK_TAG="[${GREEN}正常${NC}]"
WARN_TAG="[${YELLOW}警告${NC}]"
ERR_TAG="[${RED}故障${NC}]"
INFO_TAG="[${BLUE}信息${NC}]"
DANGER_TAG="[${RED}${BOLD}危险${NC}]"

print_header() {
    clear
    echo -e "${CYAN}${BOLD}====================================================================${NC}"
    echo -e "${CYAN}${BOLD}         ZFS 智能存储池自动检测、物理修复与 RAID 重构工具           ${NC}"
    echo -e "${CYAN}${BOLD}====================================================================${NC}"
}

# 校验各个 ZFS RAID 模式的最小硬盘限制数 (图三模式要求)
validate_disks() {
    local raid_mode=$1
    local count=$2
    case "$raid_mode" in
        1) # 单磁盘
            if [ "$count" -lt 1 ]; then
                echo -e "${RED}错误：单磁盘模式至少需要 1 块硬盘！${NC}"
                return 1
            fi
            ;;
        2) # Mirror 镜像
            if [ "$count" -lt 2 ]; then
                echo -e "${RED}错误：Mirror 镜像模式至少需要 2 块硬盘！${NC}"
                return 1
            fi
            ;;
        3) # RAID10
            if [ "$count" -lt 4 ]; then
                echo -e "${RED}错误：RAID10 模式至少需要 4 块硬盘！${NC}"
                return 1
            fi
            if [ $((count % 2)) -ne 0 ]; then
                echo -e "${RED}错误：RAID10 模式需要的硬盘数量必须为偶数 (当前为 $count 块)！${NC}"
                return 1
            fi
            ;;
        4|7) # RAIDZ / dRAID
            if [ "$count" -lt 3 ]; then
                echo -e "${RED}错误：RAIDZ/dRAID 模式至少需要 3 块硬盘！${NC}"
                return 1
            fi
            ;;
        5|8) # RAIDZ2 / dRAID2
            if [ "$count" -lt 4 ]; then
                echo -e "${RED}错误：RAIDZ2/dRAID2 模式至少需要 4 块硬盘！${NC}"
                return 1
            fi
            ;;
        6|9) # RAIDZ3 / dRAID3
            if [ "$count" -lt 5 ]; then
                echo -e "${RED}错误：RAIDZ3/dRAID3 模式至少需要 5 块硬盘！${NC}"
                return 1
            fi
            ;;
    esac
    return 0
}

# 交互选择 ZFS 存储池 (循环校验，支持 EOF 退出)
select_pool() {
    local pools_list=$(zpool list -H -o name 2>/dev/null)
    if [ -z "$pools_list" ]; then
        echo -e "${WARN_TAG} 当前系统无活跃 ZFS 存储池。"
        return 1
    fi
    local arr=($pools_list)
    while true; do
        echo -e "${INFO_TAG} 请选择要操作的 ZFS 存储池："
        for i in "${!arr[@]}"; do
            echo -e "  $((i+1)) ) ${arr[$i]}"
        done
        if ! read -p "请输入序号: " idx; then
            echo -e "\n${YELLOW}[提示] 输入流已关闭，操作已取消。${NC}"
            exit 0
        fi
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#arr[@]}" ]; then
            selected_pool="${arr[$((idx-1))]}"
            break
        else
            echo -e "${RED}选择无效，请重新输入！${NC}"
        fi
    done
    return 0
}

# 交互选择 RAID 模式 (循环校验，支持 EOF 退出，图三支持模式)
select_raid_mode() {
    while true; do
        echo -e "\n${INFO_TAG} 请选择 ZFS RAID 模式："
        echo -e "  1) ${CYAN}单磁盘 (Single / Stripe / 单物理盘)${NC} (最少 1 块)"
        echo -e "  2) ${CYAN}Mirror (镜像 / RAID1)${NC} (最少 2 块)"
        echo -e "  3) ${CYAN}RAID10 (条带镜像)${NC} (最少 4 块且须为偶数)"
        echo -e "  4) ${CYAN}RAIDZ (Raidz1 / 类似 RAID5)${NC} (最少 3 块)"
        echo -e "  5) ${CYAN}RAIDZ2 (类似 RAID6)${NC} (最少 4 块)"
        echo -e "  6) ${CYAN}RAIDZ3 (更高容错)${NC} (最少 5 块)"
        echo -e "  7) ${CYAN}dRAID (分布式 Raidz1)${NC} (最少 3 块)"
        echo -e "  8) ${CYAN}dRAID2 (分布式 Raidz2)${NC} (最少 4 块)"
        echo -e "  9) ${CYAN}dRAID3 (分布式 Raidz3)${NC} (最少 5 块)"
        if ! read -p "请输入模式序号 [1-9]: " mode_idx; then
            echo -e "\n${YELLOW}[提示] 输入流已关闭，操作已取消。${NC}"
            exit 0
        fi
        if [[ "$mode_idx" =~ ^[1-9]$ ]]; then
            selected_raid_choice="$mode_idx"
            break
        else
            echo -e "${RED}输入无效，请重新输入！${NC}"
        fi
    done
}

# 交互选择 ZFS 压缩算法 (循环校验，支持 EOF 退出，图二支持算法)
select_compression() {
    while true; do
        echo -e "\n${INFO_TAG} 请选择 ZFS 压缩算法："
        echo -e "  1) lz4 (推荐，性能与压缩比最均衡)"
        echo -e "  2) zstd (高压缩率，适合备份)"
        echo -e "  3) gzip (经典高压缩，CPU占用较高)"
        echo -e "  4) lzjb (老式算法)"
        echo -e "  5) zle (零长度编码)"
        echo -e "  6) on (默认开启)"
        echo -e "  7) off (关闭压缩)"
        if ! read -p "请输入压缩序号 [1-7, 默认 1]: " comp_choice; then
            echo -e "\n${YELLOW}[提示] 输入流已关闭，操作已取消。${NC}"
            exit 0
        fi
        comp_choice=${comp_choice:-1}
        case "$comp_choice" in
            1) selected_comp="lz4"; break ;;
            2) selected_comp="zstd"; break ;;
            3) selected_comp="gzip"; break ;;
            4) selected_comp="lzjb"; break ;;
            5) selected_comp="zle"; break ;;
            6) selected_comp="on"; break ;;
            7) selected_comp="off"; break ;;
            *) echo -e "${RED}输入无效，请选择 1-7！${NC}" ;;
        esac
    done
}

# 交互多选物理磁盘，并包含强制输入检查 (循环校验，支持 EOF 退出)
select_disks_interactive() {
    while true; do
        echo -e "\n${INFO_TAG} 请输入要加入该存储池的磁盘编号，用${BOLD}空格${NC}分隔 (例如 '1 2 3')："
        for i in "${!all_installed_disks[@]}"; do
            d="${all_installed_disks[$i]}"
            echo -e "  $((i+1)) ) /dev/$d | 大小: ${disk_sizes[$d]} | ${disk_status_desc[$d]}"
        done
        if ! read -p "请输入磁盘编号: " disk_choices; then
            echo -e "\n${YELLOW}[提示] 输入流已关闭，操作已取消。${NC}"
            exit 0
        fi
        
        if [ -z "$disk_choices" ]; then
            echo -e "${RED}未输入磁盘编号，请重新输入！${NC}"
            continue
        fi
        
        selected_devs=()
        selected_ids=()
        local invalid_found=false
        
        for choice in $disk_choices; do
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#all_installed_disks[@]}" ]; then
                idx=$((choice - 1))
                disk_name="${all_installed_disks[$idx]}"
                selected_devs+=("$disk_name")
                selected_ids+=("/dev/disk/by-id/${disk_ids[$disk_name]}")
            else
                invalid_found=true
                echo -e "${RED}无效的磁盘编号: $choice${NC}"
            fi
        done
        
        if [ "$invalid_found" = "true" ]; then
            continue
        fi
        
        disk_count=${#selected_devs[@]}
        
        # 校验最小硬盘限制
        validate_disks "$selected_raid_choice" "$disk_count"
        if [ $? -eq 0 ]; then
            break
        else
            echo -e "${RED}硬盘数量或规则校验不通过，请重新选择！${NC}"
        fi
    done
}

# 1. 检查 root 权限限制
if [ "$EUID" -ne 0 ]; then
    echo -e "${ERR_TAG} 权限不足！请使用 root 权限或 sudo 运行此脚本。"
    exit 1
fi

# 2. 检查 ZFS 工具可用性限制
if ! command -v zpool &> /dev/null; then
    echo -e "${ERR_TAG} 未检测到 zpool 命令。请确保当前系统为 Proxmox VE 且已加载 ZFS 模块！"
    exit 1
fi

print_header

# 3. 获取系统启动时间 (以计算磁盘插入时间)
boot_epoch=$(stat -c %Y /proc/1 2>/dev/null)
boot_time_str=$(date -d "@$boot_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)

# 4. 获取系统根分区物理主盘（严格保护限制）
root_parent_disk=$(basename "$(lsblk -p -o NAME,MOUNTPOINTS,TYPE | grep -B 10 -w '/' | grep 'disk' | awk '{print $1}' | head -n 1)" 2>/dev/null)
if [ -z "$root_parent_disk" ]; then
    root_parent_disk="sda" # 默认兜底
fi

# 5. 模式切换主菜单 (包含循环校验与 EOF 保护)
while true; do
    echo -e "\n${BOLD}${BLUE}==== 请选择操作模式 ====${NC}"
    echo -e " 1) ${GREEN}智能自动修复模式${NC} (仅扫描完全空闲且无分区的硬盘，安全可靠，推荐)"
    echo -e " 2) ${YELLOW}手动强制替换模式${NC} (允许选择已安装、含分区或 LVM 的硬盘，并支持主动硬盘迁移)"
    echo -e " 3) ${RED}${BOLD}ZFS 存储池管理与重构菜单${NC} (创建、删除、更改模式与压缩)"
    if ! read -p "请输入模式编号 [1-3, 默认 1]: " mode_choice; then
        echo -e "\n${YELLOW}[提示] 输入流已关闭，操作已取消。${NC}"
        exit 0
    fi
    mode_choice=${mode_choice:-1}
    
    if [[ "$mode_choice" =~ ^[1-3]$ ]]; then
        break
    else
        echo -e "${RED}输入无效，请输入 1、2 或 3！${NC}"
    fi
done

# 6. 扫描 ZFS 存储池健康度
echo -e "\n${BOLD}${BLUE}==== 步骤 1: 扫描 ZFS 存储池健康状态 ====${NC}"
pools=$(zpool list -H -o name 2>/dev/null)

if [ -z "$pools" ]; then
    echo -e "${WARN_TAG} 未发现任何活跃的 ZFS 存储池。"
    if [ "$mode_choice" -ne 3 ]; then
        exit 0
    fi
fi

degraded_pools=()
suspended_pools=()
declare -A faulted_disks_map

for pool in $pools; do
    health=$(zpool list -H -o health "$pool" 2>/dev/null)
    is_suspended=false
    if zpool status "$pool" 2>/dev/null | grep -q "state: SUSPENDED"; then
        is_suspended=true
        suspended_pools+=("$pool")
    fi
    
    echo -n -e " -> 存储池: ${BOLD}${CYAN}$pool${NC} | 状态: "
    if [ "$is_suspended" = "true" ]; then
        echo -e "${RED}[挂起 (SUSPENDED)]${NC}"
        degraded_pools+=("$pool")
    elif [ "$health" = "ONLINE" ]; then
        echo -e "${GREEN}[正常 (ONLINE)]${NC}"
    else
        echo -e "${YELLOW}[异常 ($health)]${NC}"
        degraded_pools+=("$pool")
    fi
    
    # 提取故障或丢失磁盘标识，过滤掉首列是存储池本身名称的行
    bad_disks=$(zpool status "$pool" 2>/dev/null | grep -E 'FAULTED|REMOVED|OFFLINE|UNAVAIL' | grep -v -E 'pool:|raidz|mirror|replacing|state:' | awk -v p="$pool" '$1 != p {print $1}')
    if [ -n "$bad_disks" ]; then
        faulted_disks_map["$pool"]="$bad_disks"
        echo -e "    ${YELLOW}└─ 检测到异常成员磁盘:${NC}"
        for bad in $bad_disks; do
            echo -e "       - $bad"
        done
    fi
done

# 7. 扫描硬盘设备与插入时间
echo -e "\n${BOLD}${BLUE}==== 步骤 2: 扫描系统物理磁盘与接入时间 ====${NC}"
echo -e "${INFO_TAG} 系统启动时间：${PURPLE}${boot_time_str}${NC}"
all_phys_disks=$(lsblk -d -n -o NAME,SIZE | grep -v -E 'loop|sr[0-9]')

free_disks=()
all_installed_disks=()
declare -A disk_sizes
declare -A disk_ids
declare -A disk_status_desc
declare -A disk_insert_times

while read -r line; do
    [ -z "$line" ] && continue
    disk_name=$(echo "$line" | awk '{print $1}')
    disk_size=$(echo "$line" | awk '{print $2}')
    
    # 【严格限制】禁止操作系统盘
    if [ "$disk_name" = "$root_parent_disk" ]; then
        continue
    fi
    
    # 计算磁盘接入时间
    disk_epoch=$(stat -c %Y "/dev/$disk_name" 2>/dev/null)
    diff=$((disk_epoch - boot_epoch))
    if [ "$diff" -gt 30 ]; then
        disk_insert_times["$disk_name"]="${YELLOW}$(date -d "@$disk_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null) (运行中热插拔)${NC}"
    else
        disk_insert_times["$disk_name"]="${CYAN}$(date -d "@$disk_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null) (随系统启动)${NC}"
    fi
    
    # 获取稳定的 disk-by-id
    stable_id=$(ls -la /dev/disk/by-id/ 2>/dev/null | grep -E 'scsi-|ata-|nvme-' | grep -v -E 'part[0-9]' | grep "../../$disk_name" | awk '{print $9}' | head -n 1)
    if [ -z "$stable_id" ]; then
        stable_id="$disk_name"
    fi
    
    disk_sizes["$disk_name"]="$disk_size"
    disk_ids["$disk_name"]="$stable_id"
    
    # 分析磁盘占用状态与所属池名称
    is_zfs_used=false
    belonging_pool=""
    for p in $pools; do
        if zpool status "$p" 2>/dev/null | grep -q -E "$disk_name|$stable_id"; then
            is_zfs_used=true
            belonging_pool="$p"
            break
        fi
    done
    
    # 仅当磁盘的分区被实际挂载（包含 / 等字符），或者用于 LVM（包含 lvm 字符），或者作为 Swap 时，才视为已被系统占用
    is_mounted_or_lvm=$(lsblk -n -o MOUNTPOINTS,TYPE "/dev/$disk_name" | grep -E 'lvm|/|swap|SWAP')
    
    if [ "$is_zfs_used" = "true" ]; then
        disk_status_desc["$disk_name"]="【${RED}ZFS成员盘: 属于池 [$belonging_pool]${NC}】"
    elif [ -n "$is_mounted_or_lvm" ]; then
        occupy_details=$(lsblk -n -o TYPE,MOUNTPOINTS "/dev/$disk_name" | grep -v "disk" | tr '\n' ' ' | sed 's/  */ /g')
        disk_status_desc["$disk_name"]="【${YELLOW}已占用: $occupy_details${NC}】"
    else
        disk_status_desc["$disk_name"]="【${GREEN}完全空闲${NC}】"
        free_disks+=("$disk_name")
    fi
    
    all_installed_disks+=("$disk_name")
done <<< "$all_phys_disks"

# 根据选择的模式显示磁盘列表
target_list=()
if [ "$mode_choice" -eq 1 ]; then
    echo -e "${INFO_TAG} 当前处于：${GREEN}智能自动修复模式${NC}（仅列出无分区且未被占用的空闲盘）"
    target_list=("${free_disks[@]}")
    for d in "${free_disks[@]}"; do
        echo -e " -> 物理磁盘: ${GREEN}/dev/$d${NC} | 大小: ${BOLD}${disk_sizes[$d]}${NC} | 接入时间: ${disk_insert_times[$d]} | 标识: ${CYAN}${disk_ids[$d]}${NC}"
    done
else
    echo -e "${INFO_TAG} 当前处于：${YELLOW}强制手动 / RAID重构模式${NC}（显示系统所有物理硬盘）"
    target_list=("${all_installed_disks[@]}")
    for d in "${all_installed_disks[@]}"; do
        status_str="${disk_status_desc[$d]}"
        echo -e " -> 物理磁盘: ${CYAN}/dev/$d${NC} | 大小: ${BOLD}${disk_sizes[$d]}${NC} | 状态: $status_str | 接入时间: ${disk_insert_times[$d]} | 标识: ${CYAN}${disk_ids[$d]}${NC}"
    done
fi

# 8. 智能故障分析与修复执行
echo -e "\n${BOLD}${BLUE}==== 步骤 3: 故障修复、替换与 RAID 转换 ====${NC}"

if [ "$mode_choice" -eq 3 ]; then
    # ==========================================================================
    # ==== 模式 3: ZFS 存储池管理与重构子菜单 ====
    # ==========================================================================
    while true; do
        echo -e "\n${BOLD}${BLUE}==== [选项三] ZFS 存储池管理与重构菜单 ====${NC}"
        echo -e "  1) ${GREEN}创建全新存储池${NC}"
        echo -e "  2) ${RED}删除已有存储池${NC}"
        echo -e "  3) ${YELLOW}重构现有存储池 (销毁并更改 RAID 模式/压缩/重命名)${NC}"
        echo -e "  4) ${CYAN}返回主菜单${NC}"
        if ! read -p "请选择操作 [1-4]: " sub_choice; then
            echo -e "\n${YELLOW}[提示] 输入流已关闭，操作已取消。${NC}"
            exit 0
        fi
        if [[ "$sub_choice" =~ ^[1-4]$ ]]; then
            break
        else
            echo -e "${RED}输入无效，请输入 1-4！${NC}"
        fi
    done
    
    if [ "$sub_choice" -eq 4 ]; then
        exec "$0"
    fi
    
    # --------------------------------------------------------------------------
    # 子菜单 3-1: 创建全新存储池
    # --------------------------------------------------------------------------
    if [ "$sub_choice" -eq 1 ]; then
        while true; do
            if ! read -p "请输入要新建的存储池名称 (不能与已有池同名): " new_pool_name; then
                echo -e "\n${YELLOW}[提示] 输入流已关闭，操作已取消。${NC}"
                exit 0
            fi
            if [[ ! "$new_pool_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                echo -e "${RED}名称无效！仅支持英文字母、数字、下划线和减号。${NC}"
                continue
            fi
            if zpool list -H -o name 2>/dev/null | grep -q -x "$new_pool_name"; then
                echo -e "${RED}存储池 [$new_pool_name] 已存在，请换个名字！${NC}"
                continue
            fi
            break
        done
        
        select_raid_mode
        select_compression
        select_disks_interactive
        
        # 二次确认
        echo -e "\n${INFO_TAG} 即将创建全新存储池 [$new_pool_name]，配置如下："
        echo -e "  - RAID 模式: ${CYAN}$selected_raid_choice${NC} (基于选定的 $disk_count 块磁盘)"
        echo -e "  - 压缩算法: ${CYAN}$selected_comp${NC}"
        while true; do
            if ! read -p "确认创建？[Y/n]: " create_confirm; then
                echo -e "\n${YELLOW}[提示] 输入流已关闭，操作已取消。${NC}"
                exit 0
            fi
            create_confirm=${create_confirm:-Y}
            if [[ "$create_confirm" =~ ^[YyNn]$ ]]; then
                break
            else
                echo -e "${RED}无效的确认输入，请输入 Y 或 n！${NC}"
            fi
        done
        if [[ ! "$create_confirm" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}[放弃] 创建操作已取消。${NC}"
            exit 0
        fi
        
        echo -e "${BLUE}正在组建存储池 $new_pool_name ...${NC}"
        case "$selected_raid_choice" in
            1) zpool create -f "$new_pool_name" "${selected_ids[@]}" ;;
            2) zpool create -f "$new_pool_name" mirror "${selected_ids[@]}" ;;
            3)
                cmd="zpool create -f $new_pool_name"
                for ((i=0; i<disk_count; i+=2)); do
                    cmd="$cmd mirror ${selected_ids[$i]} ${selected_ids[$((i+1))]}"
                done
                eval "$cmd"
                ;;
            4) zpool create -f "$new_pool_name" raidz1 "${selected_ids[@]}" ;;
            5) zpool create -f "$new_pool_name" raidz2 "${selected_ids[@]}" ;;
            6) zpool create -f "$new_pool_name" raidz3 "${selected_ids[@]}" ;;
            7) zpool create -f "$new_pool_name" draid "${selected_ids[@]}" ;;
            8) zpool create -f "$new_pool_name" draid2 "${selected_ids[@]}" ;;
            9) zpool create -f "$new_pool_name" draid3 "${selected_ids[@]}" ;;
        esac
        
        if [ $? -eq 0 ]; then
            zfs set compression="$selected_comp" "$new_pool_name"
            zfs mount -a
            echo -e "${BLUE}正在将存储池注册到 PVE 存储配置中...${NC}"
            pvesm add zfspool "$new_pool_name" --pool "$new_pool_name" --content rootdir,images --mountpoint "/$new_pool_name" --nodes pve 2>/dev/null
            echo -e "${GREEN}[成功] 新存储池 $new_pool_name 已成功组建并注册到 PVE 中！${NC}"
        else
            echo -e "${RED}[错误] 创建存储池失败，请确认硬盘是否良好！${NC}"
        fi
        exit 0
    fi
    
    # --------------------------------------------------------------------------
    # 子菜单 3-2: 删除已有存储池
    # --------------------------------------------------------------------------
    if [ "$sub_choice" -eq 2 ]; then
        if ! select_pool; then
            exit 0
        fi
        del_pool="$selected_pool"
        
        # 扫描关联虚拟机与容器
        associated_guests=$(grep -l -R "$del_pool:" /etc/pve/lxc/ /etc/pve/qemu-server/ 2>/dev/null | awk -F/ '{print $NF}' | sed 's/\.conf//')
        if [ -n "$associated_guests" ]; then
            echo -e "\n${DANGER_TAG} ${RED}检测到以下虚拟机或容器正使用该存储池的虚拟硬盘：${NC}"
            for guest in $associated_guests; do
                echo -e "   - 容器/虚拟机 ID: ${BOLD}${YELLOW}$guest${NC}"
            done
            echo -e "${DANGER_TAG} 若强行删除该存储池，以上容器/虚拟机的磁盘数据将【彻底丢失】！"
        fi
        
        # 强制销毁确认
        echo -e "\n${DANGER_TAG} 您将【彻底删除】存储池 [$del_pool] 并清空所有数据！"
        while true; do
            if ! read -p "请输入大写 'CONFIRM_DELETE' 以确认销毁: " delete_confirm; then
                echo -e "\n${YELLOW}[提示] 输入流已关闭，操作已取消。${NC}"
                exit 0
            fi
            if [ "$delete_confirm" = "CONFIRM_DELETE" ] || [ "$delete_confirm" = "cancel" ]; then
                break
            else
                echo -e "${RED}输入不匹配，请重新输入（输入 cancel 放弃操作）！${NC}"
            fi
        done
        if [ "$delete_confirm" != "CONFIRM_DELETE" ]; then
            echo -e "${YELLOW}[放弃] 操作已取消，存储池未受损。${NC}"
            exit 0
        fi
        
        # 停止关联容器
        if [ -n "$associated_guests" ]; then
            echo -e "${INFO_TAG} 正在停止关联的 PVE 容器与虚拟机..."
            for guest in $associated_guests; do
                pct stop "$guest" >/dev/null 2>&1
                qm stop "$guest" >/dev/null 2>&1
            done
        fi
        
        # 从 PVE 中注销存储
        if grep -q -E "^zfspool:[[:space:]]*$del_pool" /etc/pve/storage.cfg; then
            echo -e "${BLUE}正在从 PVE 存储配置中注销该存储池...${NC}"
            pvesm remove "$del_pool" >/dev/null 2>&1
        fi
        
        # 销毁 ZFS
        echo -e "${BLUE}正在销毁存储池 $del_pool ...${NC}"
        zpool destroy -f "$del_pool"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[成功] 存储池 $del_pool 及其数据已被彻底清除！${NC}"
        else
            echo -e "${RED}[错误] 销毁存储池失败！${NC}"
        fi
        exit 0
    fi
    
    # --------------------------------------------------------------------------
    # 子菜单 3-3: 重构现有存储池 (销毁重建并转换)
    # --------------------------------------------------------------------------
    if [ "$sub_choice" -eq 3 ]; then
        if ! select_pool; then
            exit 0
        fi
        old_pool="$selected_pool"
        new_pool_name="$old_pool"
        
        # 询问是否需要重命名存储池
        while true; do
            if ! read -p "是否需要重命名该存储池？(当前名称: $old_pool) [y/N]: " rename_pool_choice; then
                echo -e "\n${YELLOW}[提示] 输入流已关闭，操作已取消。${NC}"
                exit 0
            fi
            rename_pool_choice=${rename_pool_choice:-N}
            if [[ "$rename_pool_choice" =~ ^[YyNn]$ ]]; then
                break
            else
                echo -e "${RED}输入无效，请输入 y 或 n！${NC}"
            fi
        done

        if [[ "$rename_pool_choice" =~ ^[Yy]$ ]]; then
            while true; do
                if ! read -p "请输入新的存储池名称: " temp_name; then
                    echo -e "\n${YELLOW}[提示] 输入流已关闭，操作已取消。${NC}"
                    exit 0
                fi
                if [[ ! "$temp_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                    echo -e "${RED}名称无效！仅支持英文字母、数字、下划线和减号。${NC}"
                    continue
                fi
                if zpool list -H -o name 2>/dev/null | grep -q -x "$temp_name" && [ "$temp_name" != "$old_pool" ]; then
                    echo -e "${RED}存储池 [$temp_name] 已存在！${NC}"
                    continue
                fi
                new_pool_name="$temp_name"
                break
            done
        fi
        
        # 扫描关联虚拟机
        associated_guests=$(grep -l -R "$old_pool:" /etc/pve/lxc/ /etc/pve/qemu-server/ 2>/dev/null | awk -F/ '{print $NF}' | sed 's/\.conf//')
        if [ -n "$associated_guests" ]; then
            echo -e "\n${DANGER_TAG} ${RED}检测到以下虚拟机或容器正使用该存储池的虚拟硬盘：${NC}"
            for guest in $associated_guests; do
                echo -e "   - 容器/虚拟机 ID: ${BOLD}${YELLOW}$guest${NC}"
            done
            echo -e "${DANGER_TAG} 若强行重构该存储池，以上容器/虚拟机的磁盘数据将【彻底丢失】！"
        fi
        
        # 配置重构参数
        echo -e "\n${INFO_TAG} 请为重建后的存储池选择配置："
        select_raid_mode
        select_compression
        select_disks_interactive
        
        # 最终重构确认
        echo -e "\n${DANGER_TAG} 重构将【销毁】原存储池 [$old_pool]，并以名称 [$new_pool_name] 重建，原池所有数据将清空！"
        while true; do
            if ! read -p "请输入大写 'CONFIRM_REBUILD' 以确认开始重构: " rebuild_confirm; then
                echo -e "\n${YELLOW}[提示] 输入流已关闭，操作已取消。${NC}"
                exit 0
            fi
            if [ "$rebuild_confirm" = "CONFIRM_REBUILD" ] || [ "$rebuild_confirm" = "cancel" ]; then
                break
            else
                echo -e "${RED}输入不匹配，请重新输入（输入 cancel 放弃操作）！${NC}"
            fi
        done
        if [ "$rebuild_confirm" != "CONFIRM_REBUILD" ]; then
            echo -e "${YELLOW}[放弃] 操作已取消，原存储池未受损。${NC}"
            exit 0
        fi
        
        # 停止关联容器
        if [ -n "$associated_guests" ]; then
            echo -e "${INFO_TAG} 正在停止关联的 PVE 容器与虚拟机..."
            for guest in $associated_guests; do
                pct stop "$guest" >/dev/null 2>&1
                qm stop "$guest" >/dev/null 2>&1
            done
        fi
        
        # 从 PVE 注销原存储
        if grep -q -E "^zfspool:[[:space:]]*$old_pool" /etc/pve/storage.cfg; then
            echo -e "${BLUE}正在从 PVE 存储配置中注销原存储池...${NC}"
            pvesm remove "$old_pool" >/dev/null 2>&1
        fi
        
        # 销毁原池
        echo -e "${BLUE}正在销毁存储池 $old_pool ...${NC}"
        zpool destroy -f "$old_pool"
        
        # 重新创建新池
        echo -e "${BLUE}正在以新配置重新创建存储池 $new_pool_name ...${NC}"
        case "$selected_raid_choice" in
            1) zpool create -f "$new_pool_name" "${selected_ids[@]}" ;;
            2) zpool create -f "$new_pool_name" mirror "${selected_ids[@]}" ;;
            3)
                cmd="zpool create -f $new_pool_name"
                for ((i=0; i<disk_count; i+=2)); do
                    cmd="$cmd mirror ${selected_ids[$i]} ${selected_ids[$((i+1))]}"
                done
                eval "$cmd"
                ;;
            4) zpool create -f "$new_pool_name" raidz1 "${selected_ids[@]}" ;;
            5) zpool create -f "$new_pool_name" raidz2 "${selected_ids[@]}" ;;
            6) zpool create -f "$new_pool_name" raidz3 "${selected_ids[@]}" ;;
            7) zpool create -f "$new_pool_name" draid "${selected_ids[@]}" ;;
            8) zpool create -f "$new_pool_name" draid2 "${selected_ids[@]}" ;;
            9) zpool create -f "$new_pool_name" draid3 "${selected_ids[@]}" ;;
        esac
        
        if [ $? -eq 0 ]; then
            zfs set compression="$selected_comp" "$new_pool_name"
            zfs mount -a
            echo -e "${BLUE}正在将重构后的存储池重新注册到 PVE ...${NC}"
            pvesm add zfspool "$new_pool_name" --pool "$new_pool_name" --content rootdir,images --mountpoint "/$new_pool_name" --nodes pve 2>/dev/null
            echo -e "${GREEN}[成功] 存储池 $new_pool_name 已成功重构并激活！${NC}"
        else
            echo -e "${RED}[错误] 创建新存储池失败！请检查物理状态。${NC}"
        fi
        exit 0
    fi

else
    # ==========================================================================
    # ==== 模式 1 和模式 2: 修复与主动替换 ====
    # ==========================================================================
    do_manual_replace=false
    if [ "$mode_choice" -eq 2 ]; then
        if ! read -p "是否需要对现有存储池执行主动硬盘替换/迁移？[y/N]: " active_replace; then
            echo -e "\n${YELLOW}[提示] 输入流已关闭，操作已取消。${NC}"
            exit 0
        fi
        if [[ "$active_replace" =~ ^[Yy]$ ]]; then
            do_manual_replace=true
        fi
    fi

    if [ ${#degraded_pools[@]} -eq 0 ] && [ "$do_manual_replace" = "false" ]; then
        echo -e "${OK_TAG} 所有存储池健康状况良好，无需执行磁盘替换！"
        exit 0
    fi

    if [ "$do_manual_replace" = "true" ]; then
        # ==== 手动主动替换/迁移 ====
        echo -e "\n${INFO_TAG} 请选择您要操作的 ZFS 存储池："
        select pool in $pools; do
            if [ -n "$pool" ]; then
                break
            else
                echo -e "${RED}选择无效，请重新选择。${NC}"
            fi
        done
        if [ -z "$pool" ]; then
            echo -e "${YELLOW}[提示] 未选择有效存储池，操作已取消。${NC}"
            exit 0
        fi

        echo -e "${INFO_TAG} 正在查询存储池 [$pool] 中的所有成员磁盘..."
        member_disks=$(zpool status "$pool" 2>/dev/null | grep -E 'ONLINE|FAULTED|DEGRADED|REMOVED|OFFLINE' | grep -v -E 'pool:|raidz|mirror|replacing|state:' | awk -v p="$pool" '$1 != p {print $1}')
        
        if [ -z "$member_disks" ]; then
            echo -e "${ERR_TAG} 无法获取该存储池成员磁盘列表。"
            exit 1
        fi
        
        echo -e "${INFO_TAG} 请选择您要替换掉的旧磁盘 (被替换盘)："
        select old_disk in $member_disks; do
            if [ -n "$old_disk" ]; then
                break
            else
                echo -e "${RED}选择无效，请重新选择。${NC}"
            fi
        done
        if [ -z "$old_disk" ]; then
            echo -e "${YELLOW}[提示] 未选择要替换的成员磁盘，操作已取消。${NC}"
            exit 0
        fi

        echo -e "${INFO_TAG} 请选择要使用的新硬盘 (目标盘)："
        select target_disk in "${target_list[@]}"; do
            if [ -n "$target_disk" ]; then
                target_id=${disk_ids[$target_disk]}
                if [ "$old_disk" = "$target_id" ] || [ "$old_disk" = "$target_disk" ]; then
                    echo -e "${ERR_TAG} 错误：旧硬盘与新硬盘不能是同一块盘！"
                    exit 1
                fi
                break
            else
                echo -e "${RED}选择无效，请重新选择。${NC}"
            fi
        done
        if [ -z "$target_disk" ]; then
            echo -e "${YELLOW}[提示] 未选择目标硬盘，操作已取消。${NC}"
            exit 0
        fi

        selected_status="${disk_status_desc[$target_disk]}"
        if [[ ! "$selected_status" =~ "完全空闲" ]]; then
            echo -e "${DANGER_TAG} 您选择的磁盘 /dev/$target_disk 目前处于: ${RED}$selected_status${NC}"
            echo -e "${DANGER_TAG} 替换操作将【彻底清除该磁盘上的所有现有数据与分区】！"
            read -p "如果您确认此操作，请输入大写的 'YES' 进行强制覆盖: " confirm_danger
            if [ "$confirm_danger" != "YES" ]; then
                echo -e "${YELLOW}[放弃] 替换操作已被用户终止。${NC}"
                exit 0
            fi
        fi

        echo -e "${BLUE}正在下发 ZFS 替换指令...${NC}"
        zpool replace -f "$pool" "$old_disk" "/dev/disk/by-id/$target_id"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[成功] 主动替换指令已成功下发！数据重构 (Resilvering) 已开始。${NC}"
        else
            echo -e "${RED}[错误] 替换指令失败，请检查硬盘大小是否满足要求。${NC}"
        fi
        exit 0

    else
        # ==== 自动故障检测与修复替换 ====
        
        # 7.1 处理挂起（SUSPENDED）存储池
        if [ ${#suspended_pools[@]} -gt 0 ]; then
            echo -e "${ERR_TAG} 检测到有存储池处于挂起（SUSPENDED）状态！"
            echo -e "    这通常由临时物理断开或大量IO错误导致。脚本将对磁盘进行基本读写自检..."
            
            for spool in "${suspended_pools[@]}"; do
                bad_disks=${faulted_disks_map["$spool"]}
                for bad in $bad_disks; do
                    mapped_sd=$(ls -la /dev/disk/by-id/ 2>/dev/null | grep "$bad" | awk '{print $NF}' | sed 's/..\/\.\.\///')
                    if [ -n "$mapped_sd" ] && [ -b "/dev/$mapped_sd" ]; then
                        echo -e " -> 正在对故障盘 $bad (映射: /dev/$mapped_sd) 进行物理可读性自检..."
                        if dd if="/dev/$mapped_sd" of=/dev/null bs=512 count=10 >/dev/null 2>&1; then
                            echo -e "    ${GREEN}[可读]${NC} 物理设备 /dev/$mapped_sd 响应正常！"
                            echo -e "    ${YELLOW}[分析]${NC} 该硬盘已恢复连接，但内核 ZFS 线程目前由于保护机制已锁死。"
                            echo -e "    ${YELLOW}[建议]${NC} 需要安全重启系统以解除内核挂起并恢复读写。"
                            read -p "是否尝试安全重启服务器？[y/N]: " reboot_choice
                            if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
                                echo -e "${BLUE}正在发送重启指令...${NC}"
                                reboot
                                exit 0
                            fi
                        else
                            echo -e "    ${RED}[不可读]${NC} 硬盘 /dev/$mapped_sd 依然无物理响应，请检查物理连线或更换磁盘！"
                        fi
                    fi
                done
            done
        fi

        # 7.2 故障盘自动替换
        available_target_count=${#target_list[@]}
        for pool in "${degraded_pools[@]}"; do
            bad_disks=${faulted_disks_map["$pool"]}
            if [ -z "$bad_disks" ]; then
                echo -e "${WARN_TAG} 存储池 [$pool] 处于异常状态但无明确故障磁盘，尝试清除错误缓存..."
                zpool clear "$pool"
                sleep 2
                new_health=$(zpool list -H -o health "$pool" 2>/dev/null)
                echo -e " -> 执行 zpool clear 后健康状态: ${BOLD}$new_health${NC}"
                continue
            fi
            
            for bad in $bad_disks; do
                echo -e "${WARN_TAG} 存储池 [$pool] 中的磁盘 [$bad] 丢失或损坏。"
                
                if [ $available_target_count -eq 0 ]; then
                    echo -e "${ERR_TAG} 无法执行替换：当前模式下无可用的目标磁盘！请切换模式或插入新磁盘。"
                    continue
                fi
                
                selected_disk=""
                
                if [ $available_target_count -eq 1 ] && [ "$mode_choice" -eq 1 ]; then
                    target_disk=${target_list[0]}
                    target_id=${disk_ids[$target_disk]}
                    echo -e "${INFO_TAG} 检测到唯一可用的空闲硬盘: ${GREEN}/dev/$target_disk${NC} (ID: $target_id)"
                    read -p "确认将故障盘 $bad 替换为新盘 $target_disk 吗？[Y/n]: " choice
                    choice=${choice:-Y}
                    if [[ "$choice" =~ ^[Yy]$ ]]; then
                        selected_disk="$target_disk"
                    fi
                else
                    echo -e "${INFO_TAG} 请选择一个用于替换故障盘 [$bad] 的硬盘："
                    select choice_disk in "${target_list[@]}"; do
                        if [ -n "$choice_disk" ]; then
                            selected_disk="$choice_disk"
                            break
                        else
                            echo -e "${RED}输入无效，请重新选择。${NC}"
                        fi
                    done
                fi
                
                if [ -n "$selected_disk" ]; then
                    selected_id=${disk_ids[$selected_disk]}
                    selected_status="${disk_status_desc[$selected_disk]}"
                    
                    if [[ ! "$selected_status" =~ "完全空闲" ]]; then
                        echo -e "${DANGER_TAG} 您选择的磁盘 /dev/$selected_disk 目前处于: ${RED}$selected_status${NC}"
                        echo -e "${DANGER_TAG} 替换操作将【彻底清除该磁盘上的所有现有数据与分区】！"
                        read -p "如果您确认此操作，请输入大写的 'YES' 进行强制覆盖: " confirm_danger
                        if [ "$confirm_danger" != "YES" ]; then
                            echo -e "${YELLOW}[放弃] 替换已被用户终止。${NC}"
                            continue
                        fi
                    fi
                    
                    echo -e "${BLUE}正在下发 ZFS 替换指令...${NC}"
                    zpool replace -f "$pool" "$bad" "/dev/disk/by-id/$selected_id"
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}[成功] 替换指令已成功下发！数据重构 (Resilvering) 已开始。${NC}"
                    else
                        echo -e "${RED}[错误] 替换指令失败！请检查所选磁盘的物理状态或手动运行：${NC}"
                        echo -e "      zpool replace -f $pool $bad /dev/disk/by-id/$selected_id"
                    fi
                fi
            done
        done
    fi
fi

# 9. 显示最新状态与同步进度
echo -e "\n${BOLD}${BLUE}==== 步骤 4: ZFS 修复进度确认 ====${NC}"
zpool status
echo -e "${CYAN}${BOLD}====================================================================${NC}"
echo -e "${GREEN}ZFS 自动检测与修复操作完成。${NC}"
