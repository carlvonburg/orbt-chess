//! Ported from StatisticsTests.swift.

use std::collections::{BTreeSet, HashMap};

use super::*;
use crate::chess::ChessPosition;
use crate::training::anki::{
    Card, CardQueue, CardType, MemoryState, RevlogEntry, RevlogReviewKind,
};

fn timing() -> SchedTiming {
    SchedTiming::new(100, 1_000_000 + 16 * 3600, 1_000_000)
}

fn e4() -> Epd {
    ChessPosition::start().epd()
}

fn entry(secs_ago: i64, ease: i64, last_ivl: i64, kind: RevlogReviewKind) -> RevlogEntry {
    RevlogEntry {
        id: (timing().now - secs_ago) * 1000,
        cid: e4(),
        ease,
        ivl: 1,
        last_ivl,
        factor: 500,
        time: 4000,
        kind,
    }
}

#[test]
fn today_and_retention() {
    let revlog = vec![
        entry(60, 3, 0, RevlogReviewKind::Learning),
        entry(120, 1, 30, RevlogReviewKind::Review),
        entry(180, 3, 5, RevlogReviewKind::Review),
        entry(2 * 86_400, 3, 30, RevlogReviewKind::Review),
    ];
    let graphs = GraphsContext::new(vec![], 0, 0, revlog, timing(), 0);
    let today = graphs.today();
    assert_eq!(today.answer_count, 3);
    assert_eq!(today.correct_count, 2);
    assert!(today.mature_count == 1 && today.mature_correct == 0);
    assert!(today.learn_count == 1 && today.review_count == 2);
    let retention = graphs.true_retention(None);
    // learning answers (interval below a day) are not counted
    let t = retention[&RetentionPeriod::Today];
    assert_eq!(t.count(), 2);
    assert!(t.young_passed == 1 && t.mature_failed == 1);
    assert_eq!(retention[&RetentionPeriod::Week].mature_passed, 1);
    assert_eq!(graphs.reviews().count[&0].total(), 3);
    assert_eq!(graphs.reviews().count[&-2].mature, 1);
}

#[test]
fn card_counts_and_expected_recall() {
    let review = Card {
        ctype: CardType::Review,
        queue: CardQueue::Review,
        interval: 30,
        memory: Some(MemoryState {
            stability: 30.0,
            difficulty: 5.0,
        }),
        last_review_time: Some(timing().now),
        ..Card::new(1, 0, 0)
    };
    let graphs = GraphsContext::new(vec![review.clone()], 2, 0, vec![], timing(), 0);
    assert_eq!(
        graphs.card_counts(),
        CardCounts {
            new: 2,
            mature: 1,
            ..CardCounts::default()
        }
    );
    let other = ChessPosition::start().play_san("d4").unwrap().1.epd();
    let recall = expected_recall(
        &HashMap::from([(e4(), review)]),
        &HashMap::from([(e4(), 1.0), (other, 1.0)]),
        timing().now as f64,
    );
    // the studied move is known (R = 1), the other is new (R = 0)
    assert_eq!(recall, Some(0.5));
}

#[test]
fn streak_current_and_longest() {
    let days = |d: &[i64]| d.iter().copied().collect::<BTreeSet<i64>>();
    assert_eq!(
        Streak::from_days(&days(&[0, -1, -2, -5, -6, -7, -8])),
        Streak {
            current: 3,
            longest: 4,
            studied_today: true
        }
    );
    // Not studied yet today: yesterday's streak still counts.
    assert_eq!(
        Streak::from_days(&days(&[-1, -2])),
        Streak {
            current: 2,
            longest: 2,
            studied_today: false
        }
    );
    assert_eq!(Streak::from_days(&days(&[-2, -3])).current, 0);
    assert_eq!(Streak::from_days(&days(&[])), Streak::default());
}
