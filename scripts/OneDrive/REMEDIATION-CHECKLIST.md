# 🔧 Checklist de Remediação - OneDrive for Business

Este checklist complementa o script de auditoria `OneDrive-Complete-Audit.ps1`.

> **⚠️ IMPORTANTE:** A remediação deve ser feita **manualmente** no SharePoint Admin Center.
> A Microsoft Graph API não permite escrita nas configurações de SharePoint/OneDrive.

## 📍 Acesso ao Admin Center

```
https://<seu-tenant>-admin.sharepoint.com
```

---

## 🔴 CRÍTICOS (Corrigir Imediatamente)

### 1. Compartilhamento Externo (Anyone Links)

**Local:** `Policies > Sharing`

| Ação | Configuração |
|------|-------------|
| ✅ | External sharing: Selecionar **"New and existing guests"** ou **"Only people in your organization"** |
| ✅ | Desmarcar **"Allow guests to share items they don't own"** |

### 2. Autenticação Legacy

**Local:** `Access control > Apps that don't use modern authentication`

| Ação | Configuração |
|------|-------------|
| ✅ | Selecionar **"Block access"** |

### 3. Download de Arquivos Infectados

**Local:** `Settings`

| Ação | Configuração |
|------|-------------|
| ✅ | Marcar **"Disallow users from downloading files detected by ATP"** |

---

## 🟠 ALTOS (Corrigir em 1-2 semanas)

### 4. Tipo de Link Padrão

**Local:** `Policies > Sharing > File and folder links`

| Ação | Configuração |
|------|-------------|
| ✅ | Default link type: **"Specific people"** |
| ✅ | Default permission: **"View"** |

### 5. Expiração de Links

**Local:** `Policies > Sharing > More external sharing settings`

| Ação | Configuração |
|------|-------------|
| ✅ | Marcar **"Anyone links must expire within this many days"**: **14 dias** |
| ✅ | Marcar **"People who use a verification code must reauthenticate after this many days"**: **30 dias** |

### 6. Expiração de Acesso Externo

**Local:** `Policies > Sharing > More external sharing settings`

| Ação | Configuração |
|------|-------------|
| ✅ | Marcar **"Guest access to a site or OneDrive will expire automatically after this many days"**: **60 dias** |

### 7. Restrição de Sync

**Local:** `Settings > OneDrive > Sync`

| Ação | Configuração |
|------|-------------|
| ✅ | Marcar **"Allow syncing only on computers joined to specific domains"** |
| ✅ | Adicionar seus domínios corporativos (GUID do domínio AD) |

### 8. Controle de Dispositivos Não Gerenciados

**Local:** `Access control > Unmanaged devices`

| Ação | Configuração |
|------|-------------|
| ✅ | Selecionar **"Allow limited, web-only access"** |

### 9. Conta Corresponde ao Convite

**Local:** `Policies > Sharing > More external sharing settings`

| Ação | Configuração |
|------|-------------|
| ✅ | Marcar **"Guests must sign in using the same account to which sharing invitations are sent"** |

---

## 🟡 MÉDIOS (Avaliar em 1 mês)

### 10. Restrição de Domínios

**Local:** `Policies > Sharing > More external sharing settings`

| Ação | Configuração |
|------|-------------|
| ⚙️ | Marcar **"Limit external sharing by domain"** |
| ⚙️ | Adicionar domínios permitidos ou bloqueados |

### 11. Notificações

**Local:** `Policies > Sharing`

| Ação | Configuração |
|------|-------------|
| ✅ | Marcar **"When guests accept sharing invitations, send email notification to the sharer"** |
| ✅ | Marcar **"When guests reshare items, send email notification to the item owner"** |

### 12. Retenção de OneDrive Órfão

**Local:** `Settings > OneDrive > Retention`

| Ação | Configuração |
|------|-------------|
| ✅ | Definir **"Days to retain a deleted user's OneDrive"**: **90 dias** |

### 13. Extensões Bloqueadas para Sync

**Local:** `Settings > OneDrive > Sync`

| Ação | Configuração |
|------|-------------|
| ✅ | Marcar **"Block specific file types from syncing"** |
| ✅ | Adicionar: `exe, bat, cmd, ps1, vbs, js, jar, msi, dll` |

### 14. Restrição por IP (Opcional)

**Local:** `Access control > Network location`

| Ação | Configuração |
|------|-------------|
| ⚙️ | Marcar **"Allow access only from specific IP address ranges"** |
| ⚙️ | Adicionar IPs corporativos |

---

## 🔵 BAIXOS (Melhorias Recomendadas)

### 15. Integração Azure AD B2B

**Local:** `Policies > Sharing`

| Ação | Configuração |
|------|-------------|
| ✅ | Marcar **"Enable Azure AD B2B integration for sharing"** |

---

## 📋 Ordem de Execução Recomendada

```
1. Backup - Documentar configurações atuais
2. Críticos - Items 1-3 (imediato)
3. Altos - Items 4-9 (1-2 semanas)
4. Médios - Items 10-14 (1 mês)
5. Baixos - Item 15 (quando possível)
6. Validação - Re-executar auditoria
7. Monitoramento - Agendar auditorias mensais
```

---

## ⚠️ Considerações

- **Comunicação:** Avise os usuários antes de aplicar restrições
- **Teste:** Valide cada alteração em um grupo piloto
- **Documentação:** Registre todas as alterações feitas
- **Rollback:** Tenha um plano de reversão

---

## 🔗 Links Úteis

- [SharePoint Admin Center](https://admin.microsoft.com/sharepoint)
- [Microsoft 365 Security Center](https://security.microsoft.com)
- [Entra ID (Azure AD)](https://entra.microsoft.com)
- [Documentação Microsoft - Sharing](https://docs.microsoft.com/sharepoint/turn-external-sharing-on-or-off)

---

*Checklist gerado para complementar OneDrive-Complete-Audit.ps1 v5.0*
