#!/bin/bash

# ============================================
# Verificação de DNS - SPF, DKIM, DMARC
# M365 Security Toolkit
# ============================================
#
# Uso:
#   chmod +x check-dns.sh
#   ./check-dns.sh
#
# Edite a variável DOMAINS abaixo para adicionar seus domínios
# ============================================

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  🔍 VERIFICAÇÃO DNS - SPF, DKIM, DMARC                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# ==================================================
# EDITE AQUI: Adicione seus domínios
# ==================================================
DOMAINS=("seudominio.com.br" "outrodominio.com")
# ==================================================

for DOMAIN in "${DOMAINS[@]}"; do
    echo "═══════════════════════════════════════════════════════════"
    echo "📌 Domínio: $DOMAIN"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    # SPF
    echo "📧 SPF Record:"
    echo "-----------------------------------------------------------"
    SPF=$(dig +short TXT $DOMAIN | grep "v=spf1")
    if [ -n "$SPF" ]; then
        echo "✅ $SPF"
        
        # Verificar se inclui Microsoft
        if echo "$SPF" | grep -q "spf.protection.outlook.com"; then
            echo "   ✅ Inclui Microsoft 365"
        else
            echo "   ⚠️  NÃO inclui Microsoft 365"
        fi
        
        # Verificar política
        if echo "$SPF" | grep -q "\-all"; then
            echo "   ✅ Política: Hard Fail (-all) - Recomendado"
        elif echo "$SPF" | grep -q "~all"; then
            echo "   ℹ️  Política: Soft Fail (~all) - Aceitável"
        elif echo "$SPF" | grep -q "?all"; then
            echo "   ⚠️  Política: Neutral (?all) - Não recomendado"
        fi
    else
        echo "❌ NÃO ENCONTRADO"
    fi
    echo ""
    
    # DKIM (Selectores Microsoft)
    echo "🔐 DKIM Records (Microsoft):"
    echo "-----------------------------------------------------------"
    
    # Selector 1
    DKIM1=$(dig +short CNAME selector1._domainkey.$DOMAIN)
    if [ -n "$DKIM1" ]; then
        echo "✅ Selector 1: $DKIM1"
    else
        echo "⚠️  Selector 1: Não encontrado (pode estar como TXT)"
        DKIM1_TXT=$(dig +short TXT selector1._domainkey.$DOMAIN)
        if [ -n "$DKIM1_TXT" ]; then
            echo "   ✅ Encontrado como TXT"
        fi
    fi
    
    # Selector 2
    DKIM2=$(dig +short CNAME selector2._domainkey.$DOMAIN)
    if [ -n "$DKIM2" ]; then
        echo "✅ Selector 2: $DKIM2"
    else
        echo "⚠️  Selector 2: Não encontrado (pode estar como TXT)"
    fi
    echo ""
    
    # DMARC
    echo "🛡️  DMARC Record:"
    echo "-----------------------------------------------------------"
    DMARC=$(dig +short TXT _dmarc.$DOMAIN)
    if [ -n "$DMARC" ]; then
        echo "✅ $DMARC"
        
        # Verificar política
        if echo "$DMARC" | grep -q "p=reject"; then
            echo "   ✅ Política: REJECT - Máxima proteção"
        elif echo "$DMARC" | grep -q "p=quarantine"; then
            echo "   ✅ Política: QUARANTINE - Boa proteção"
        elif echo "$DMARC" | grep -q "p=none"; then
            echo "   ⚠️  Política: NONE - Apenas monitoramento"
        fi
        
        # Verificar relatórios
        if echo "$DMARC" | grep -q "rua="; then
            echo "   ✅ Relatórios agregados (rua) configurados"
        fi
        if echo "$DMARC" | grep -q "ruf="; then
            echo "   ✅ Relatórios forenses (ruf) configurados"
        fi
    else
        echo "❌ NÃO ENCONTRADO"
        echo ""
        echo "   📝 Registro DMARC recomendado:"
        echo "   v=DMARC1; p=quarantine; rua=mailto:dmarc@$DOMAIN; pct=100"
    fi
    echo ""
    echo ""
done

# MX Records
echo "═══════════════════════════════════════════════════════════"
echo "📬 MX RECORDS"
echo "═══════════════════════════════════════════════════════════"
echo ""

for DOMAIN in "${DOMAINS[@]}"; do
    echo "📌 $DOMAIN:"
    dig +short MX $DOMAIN | sort -n
    echo ""
done

echo ""
echo "✅ Verificação concluída!"
echo ""
