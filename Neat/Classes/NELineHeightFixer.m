//
//  NELineHeightFixer.m
//  Neat
//
//  Created by Gao on 3/25/17.
//  Copyright © 2017 leave. All rights reserved.
//

#import "NELineHeightFixer.h"
#import "NELineHeightFixerInner.h"
#import <CoreText/CoreText.h>

#if TARGET_OS_OSX
#define SystemImage NSImage
#else
#define SystemImage UIImage
#endif

@implementation NELineHeightFixer {
    NSRecursiveLock *_attachmentLock;
    NSMapTable *_attachmentTable;
}

- (id)init {
    self = [super init];
    if (self) {
        _attachmentLock = [[NSRecursiveLock alloc]init];
        _attachmentTable = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

+ (instancetype)sharedInstance {
    static id instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

+ (CGFloat)fixedLineHeightForFontSize:(CGFloat)fontSize paragraphStyle:(NSParagraphStyle *)style {
    return [self lineHeightForFont:[Font systemFontOfSize:fontSize] paragraphStyle:style];
}

- (BOOL)layoutManager    :(NSLayoutManager *)layoutManager
shouldSetLineFragmentRect:(inout CGRect *)lineFragmentRect
     lineFragmentUsedRect:(inout CGRect *)lineFragmentUsedRect
           baselineOffset:(inout CGFloat *)baselineOffset
          inTextContainer:(NSTextContainer *)textContainer
            forGlyphRange:(NSRange)glyphRange
{

    // --- get info ---
    Font *font;
    NSParagraphStyle *style;
    NSArray *attrsList = [self attributesListForGlyphRange:glyphRange layoutManager:layoutManager];
    [self getFont:&font paragraphStyle:&style fromAttibutesList:attrsList];

    if (![font isKindOfClass:[Font class]]) {
        return NO;
    }

    Font *defaultFont = [self systemDefaultFontForFont:font];


    // --- calculate the rects ---
    CGRect rect = *lineFragmentRect;
    CGRect usedRect = *lineFragmentUsedRect;

    // calculate the right line fragment height
    CGFloat attachmentsHeight = [self maximumHeightOfAttachmentsInGlyphRange:glyphRange layoutManager:layoutManager];
    CGFloat textOnlyLineHeight = [self.class lineHeightForFont:defaultFont paragraphStyle:style];
    CGFloat textLineHeight = MAX(textOnlyLineHeight, attachmentsHeight);
    CGFloat fixedBaseLineOffset = [self.class baseLineOffsetForLineHeight:textLineHeight font:defaultFont];

    rect.size.height = textLineHeight;
    // Some font (like emoji) have large lineHeight than the one we calculated. If we set the usedRect
    // to a small line height, it will make the last line to disappear. So here we only adopt the calcuated
    // lineHeight when is larger than the original.
    //
    // This may lead to a unwanted result that textView have extra pading below last line. To solve this
    // problem, you could set maxLineHeight to lineHeight we calculated using ``.
    usedRect.size.height = MAX(textLineHeight, usedRect.size.height);


    /*
     From apple's doc:
     https://developer.apple.com/library/content/documentation/StringsTextFonts/Conceptual/TextAndWebiPhoneOS/CustomTextProcessing/CustomTextProcessing.html
     In addition to returning the line fragment rectangle itself, the layout manager returns a rectangle called the used rectangle. This is the portion of the line fragment rectangle that actually contains glyphs or other marks to be drawn. By convention, both rectangles include the line fragment padding and the interline space (which is calculated from the font’s line height metrics and the paragraph’s line spacing parameters). However, the paragraph spacing (before and after) and any space added around the text, such as that caused by center-spaced text, are included only in the line fragment rectangle, and are not included in the used rectangle.
     */

    CGRect strippedRect = rect;
    NSInteger lastIndexOfCurrentRange = glyphRange.location + glyphRange.length - 1;

    // line spacing
    {
        // Althought the doc said usedRect should container lineSpacing,
        // we don't add the lineSpacing to usedRect to avoid the case that
        // last sentance have a extra lineSpacing pading.

        SEL sel = @selector(layoutManager:lineSpacingAfterGlyphAtIndex:withProposedLineFragmentRect:);
        CGFloat lineSpacing = 0;
        if ([self.realTarget respondsToSelector:sel]) {
            lineSpacing = [self.realTarget layoutManager:layoutManager lineSpacingAfterGlyphAtIndex:lastIndexOfCurrentRange withProposedLineFragmentRect:strippedRect];
        } else if (style) {
            lineSpacing = style.lineSpacing;
        }
        rect.size.height += lineSpacing;
    }

    // paragraphSpacing
    {
        SEL sel = @selector(layoutManager:paragraphSpacingBeforeGlyphAtIndex:withProposedLineFragmentRect:);
        BOOL methodImplemented = [layoutManager.delegate respondsToSelector:sel];
        if (style.paragraphSpacing != 0 || methodImplemented ) {
            NSTextStorage *textStorage = layoutManager.textStorage;
            NSRange charaterRange = [layoutManager characterRangeForGlyphRange:NSMakeRange(glyphRange.location + glyphRange.length-1, 1) actualGlyphRange:nil];
            NSAttributedString *s = [textStorage attributedSubstringFromRange:charaterRange];
            if ([s.string isEqualToString:@"\n"]) {

                if (methodImplemented) {
                    CGFloat space = [layoutManager.delegate layoutManager:layoutManager paragraphSpacingAfterGlyphAtIndex:lastIndexOfCurrentRange withProposedLineFragmentRect:strippedRect];
                    rect.size.height += space;
                } else {
                    rect.size.height += style.paragraphSpacing;
                }
            }
        }
    }
    // paragraphSpacing before
    {
        SEL sel = @selector(layoutManager:paragraphSpacingBeforeGlyphAtIndex:withProposedLineFragmentRect:);
        BOOL methodImplemented = [layoutManager.delegate respondsToSelector:sel];

        if (glyphRange.location > 0 && (style.paragraphSpacingBefore > 0 || methodImplemented) )
        {
            NSTextStorage *textStorage = layoutManager.textStorage;
            NSRange lastLineEndRange = NSMakeRange(glyphRange.location-1, 1);
            NSRange charaterRange = [layoutManager characterRangeForGlyphRange:lastLineEndRange actualGlyphRange:nil];
            NSAttributedString *s = [textStorage attributedSubstringFromRange:charaterRange];
            if ([s.string isEqualToString:@"\n"]) {

                CGFloat space = 0;
                if (methodImplemented) {
                    space = [layoutManager.delegate layoutManager:layoutManager paragraphSpacingBeforeGlyphAtIndex:glyphRange.location withProposedLineFragmentRect:strippedRect];
                } else {
                    space = style.paragraphSpacingBefore;
                }
                usedRect.origin.y += space;
                rect.size.height += space;
                fixedBaseLineOffset += space;
            }
        }
    }

    // fix ghost selection area issue
    rect.size.height = ceil(rect.size.height);
    // fix background gap
    usedRect.size.height = ceil(usedRect.size.height);
    
    // vertical alignment in line
    const CGFloat lineMultiply = style.lineHeightMultiple > 0 ? style.lineHeightMultiple : 1.0;
    fixedBaseLineOffset = ceil(fixedBaseLineOffset - (rect.size.height - rect.size.height / lineMultiply) / 2);
    
    *lineFragmentRect = rect;
    *lineFragmentUsedRect = usedRect;
    *baselineOffset = fixedBaseLineOffset;
    return YES;
}



// Implementing this method with a return value 0 will solve the problem of last line disappearing
// when both maxNumberOfLines and lineSpacing are set, since we didn't include the lineSpacing in
// the lineFragmentUsedRect.
- (CGFloat)layoutManager:(NSLayoutManager *)layoutManager lineSpacingAfterGlyphAtIndex:(NSUInteger)glyphIndex withProposedLineFragmentRect:(CGRect)rect {
    return 0;
}

#pragma mark - private


+ (CGFloat)lineHeightForFont:(Font *)font paragraphStyle:(NSParagraphStyle *)style  {
    CTFontRef coreFont = (__bridge CTFontRef)font;
    CGFloat lineHeight = CTFontGetAscent(coreFont) + ABS(CTFontGetDescent(coreFont)) + CTFontGetLeading(coreFont);
    if (!style) {
        return lineHeight;
    }
    if (style.lineHeightMultiple > 0) {
        lineHeight *= style.lineHeightMultiple;
    }
    if (style.minimumLineHeight > 0) {
        lineHeight = MAX(style.minimumLineHeight, lineHeight);
    }
    if (style.maximumLineHeight > 0) {
        lineHeight = MIN(style.maximumLineHeight, lineHeight);
    }
    return lineHeight;
}


+ (CGFloat)baseLineOffsetForLineHeight:(CGFloat)lineHeight font:(Font *)font {
    CGFloat baseLine = lineHeight + font.descender;
    return baseLine;
}

/// get system default font of size
- (Font *)systemDefaultFontForFont:(Font *)font {
    return [Font systemFontOfSize:font.pointSize];
}


- (NSArray<NSDictionary *> *)attributesListForGlyphRange:(NSRange)glyphRange layoutManager:(NSLayoutManager *)layoutManager {

    // exclude the line break. System doesn't calucate the line rect with it.
    if (glyphRange.length > 1) {
        NSGlyphProperty property = [layoutManager propertyForGlyphAtIndex:glyphRange.location + glyphRange.length - 1];
        if (property & NSGlyphPropertyControlCharacter) {
            glyphRange = NSMakeRange(glyphRange.location, glyphRange.length - 1);
        }
    }

    
    NSTextStorage *textStorage = layoutManager.textStorage;
    NSRange targetRange = [layoutManager characterRangeForGlyphRange:glyphRange actualGlyphRange:nil];
    NSMutableArray *dicts = [NSMutableArray arrayWithCapacity:2];

    NSInteger last = -1;
    NSRange effectRange = NSMakeRange(targetRange.location, 0);

    while (effectRange.location + effectRange.length < targetRange.location + targetRange.length) {
        NSInteger current = effectRange.location + effectRange.length;
        // if effectRange didn't advanced, we manuly add 1 to avoid infinate loop.
        if (current <= last) {
            current += 1;
        }
        NSMutableDictionary *attributes = [[textStorage attributesAtIndex:current effectiveRange:&effectRange]mutableCopy];
        if (attributes) {
            [dicts addObject:attributes];
        }
        last = current;
    }

    return dicts;
}

- (void)getFont:(Font **)returnFont paragraphStyle:(NSParagraphStyle **)returnStyle fromAttibutesList:(NSArray<NSDictionary *> *)attributesList {

    if (attributesList.count == 0) {
        return;
    }

    Font *findedFont = nil;
    NSParagraphStyle *findedStyle = nil;
    CGFloat lastHeight = -CGFLOAT_MAX;

    // find the attributes with max line height
    for (NSInteger i = 0; i < attributesList.count; i++) {
        NSDictionary *attrs = attributesList[i];

        NSParagraphStyle *style = attrs[NSParagraphStyleAttributeName];
        Font *font = attrs[NSFontAttributeName];

        if ([font isKindOfClass:[Font class]] &&
            (!style || [style isKindOfClass:[NSParagraphStyle class]]) ) {

            CGFloat height = [self.class lineHeightForFont:font paragraphStyle:style];
            if (height > lastHeight) {
                lastHeight = height;
                findedFont = font;
                findedStyle = style;
            }
        }
    }

    *returnFont = findedFont;
    *returnStyle = findedStyle;
}

- (CGFloat)maximumHeightOfAttachmentsInGlyphRange:(NSRange)glyphRange layoutManager:(NSLayoutManager *)layoutManager {
    __block CGFloat result = 0;
    NSRange characterRange = [layoutManager characterRangeForGlyphRange:glyphRange actualGlyphRange:nil];
    [layoutManager.textStorage enumerateAttribute:NSAttachmentAttributeName inRange:characterRange options:0 usingBlock:^(id  _Nullable value, NSRange range, BOOL * _Nonnull stop) {
        NSTextAttachment *attachment = value;
        [self->_attachmentLock lock];
        if ([self->_attachmentTable objectForKey:attachment] == nil) {
            CGSize imageSize = [[SystemImage alloc]initWithData:[attachment.fileWrapper regularFileContents]].size;
#if TARGET_OS_OSX
            NSValue *wrappedSize = [NSValue valueWithSize:imageSize];
#else
            NSValue *wrappedSize = [NSValue valueWithCGSize:imageSize];
#endif
            [self->_attachmentTable setObject:wrappedSize forKey:attachment];
        }
        NSValue *storedSize = [self->_attachmentTable objectForKey:attachment];
#if TARGET_OS_OSX
        CGSize attachmentSize = [storedSize sizeValue];
#else
        CGSize attachmentSize = [storedSize CGSizeValue];
#endif
        [self->_attachmentLock unlock];
        if (attachmentSize.height > result) {
            result = attachmentSize.height;
        }
    }];
    return result;
}

@end
