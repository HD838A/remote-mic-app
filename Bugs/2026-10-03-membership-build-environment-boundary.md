# 会员构建环境边界

## 复现与原因

基于 origin/main 36eebf33 的本地集成构建预检失败：公开宿主 build-app.sh 仍接受任意会员 API URL，并写入 Info.plist。环境选择已由可选会员 Host Adapter 管理，旧入口与现行构建边界冲突。

## 修复

移除 build-app.sh 的旧地址变量、校验和 Info.plist 写入；公开宿主继续通过可选适配器使用会员能力。增加 BuildSigningTests 静态合同，防止 Package.swift、构建和校验入口恢复该字段。

## 验证

zsh 语法检查和 BuildSigningTests 通过。此项只修正本地构建入口，不部署服务或变更用户数据。
