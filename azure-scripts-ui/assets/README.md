# Assets Directory

Este diretório contém recursos estáticos para o Azure Scripts UI.

## Ícones Necessários

Para distribuição, adicione os seguintes arquivos:

- `icon.png` - Ícone PNG 512x512 (usado no Linux e como base)
- `icon.icns` - Ícone para macOS (pode ser gerado a partir do PNG)
- `icon.ico` - Ícone para Windows (pode ser gerado a partir do PNG)

## Gerando Ícones

### Usando electron-icon-maker (recomendado)

```bash
npm install -g electron-icon-maker
electron-icon-maker --input=icon.png --output=./
```

### Manualmente

- **macOS**: Use o app `Image2Icon` ou `iconutil`
- **Windows**: Use [ConvertICO](https://convertico.com/) ou similar
- **Linux**: PNG 512x512 é suficiente

## Design Sugerido

O ícone deve seguir o padrão visual Azure:
- Fundo: Gradiente azul (#0078D4 → #005A9E)
- Símbolo: Logo Azure estilizado em azul claro (#50E6FF)
- Formato: Quadrado com cantos arredondados
